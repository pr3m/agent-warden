# Native Roam Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give Agent Warden its own roam mode — keep the Mac awake and working with the lid closed, toggled from Warden's UI, with the bubble showing roam state and Claude Code session footers still reading `🎒 roam on` — with no dependency on the `claude-code-roam` plugin.

**Architecture:** A root LaunchDaemon (`dev.agentwarden.powerd`) owns the one privileged operation, writing the global `SleepDisabled` setting via `pmset`, and grants it only as an **exclusive, heartbeat-renewed lease** so a crashed or wedged Warden cannot leave the machine awake. The app holds an idle-sleep IOKit assertion, renews the lease every 10 seconds, and sleeps the machine itself via `IOPMSleepSystem` when the battery runs low. All policy — lease expiry, battery thresholds, hotspot classification, indicator text, halo geometry — is pure code in `AgentAttentionCore` and unit-tested; the privileged and AppKit edges are thin wrappers verified by hand.

**Tech Stack:** Swift 6 toolchain in Swift 5 language mode, SwiftPM, swift-testing (`import Testing`), AppKit, IOKit power management, launchd socket activation, Unix domain sockets.

**Spec:** `docs/superpowers/specs/2026-09-09-native-roam-design.md`

## Global Constraints

Copied verbatim from the spec and the repo's existing conventions. Every task's requirements implicitly include this section.

- **Platform:** macOS 14+ (`.macOS(.v14)` in `Package.swift`). Roam is macOS-only.
- **Language mode:** every target uses `swiftSettings: [.swiftLanguageMode(.v5)]`, matching all existing targets except `AASession`.
- **Tests:** swift-testing (`import Testing`, `@Suite`, `@Test`, `#expect`). Run with `./Scripts/test.sh` — **not** bare `swift test`, which fails with `no such module 'Testing'` on this machine's Command Line Tools. Filter with `./Scripts/test.sh --filter "<name>"`.
- **Pure policy lives in `AgentAttentionCore`.** `AgentAttentionApp` is an executable target and cannot be imported by tests. Anything that needs a unit test goes in Core.
- **NO COMMITS.** This repo's standing rule is that commits happen only when the user explicitly asks, and that rule binds skills and plans that would commit by default. Every task therefore ends at a **review checkpoint**, not a commit. Report what changed, what passes, and stop.
- **No watchers or background servers.** One-shot runners only.
- **Privileged paths are fixed constants**, never read from `install-manifest.json` or any other user-writable file.
- **The daemon must never load code, config or paths the installing user can modify.**
- **Every `pmset` write is verified by read-back.** Unverified means failed, and is reported as failed.
- **`SleepDisabled` is global, not reference-counted.** If it is already `1`, `acquire` refuses with `error foreign`. Never take it over.
- **The assertion is idle-only:** `kIOPMAssertionTypePreventUserIdleSystemSleep`. Do **not** assert display sleep.
- **Emergency repair, printed by the installer and documented in the README:** `sudo pmset -a disablesleep 0`.

---

## File Structure

### Phase 1 — the privileged daemon

| File | Responsibility |
|---|---|
| Create `Sources/AgentAttentionCore/SleepDisabled.swift` | Parse `pmset -g` output into a `SleepDisabled` reading. Pure. |
| Create `Sources/AgentAttentionCore/PowerProtocol.swift` | Encode and decode the daemon's line protocol. Pure. |
| Create `Sources/AgentAttentionCore/PowerLease.swift` | The exclusive, heartbeat-renewed lease state machine. Pure. |
| Create `Sources/AAPowerd/main.swift` | Daemon entry point: socket activation, run loop. |
| Create `Sources/AAPowerd/PowerDaemon.swift` | Accept loop, peer check, verb dispatch, expiry timer. |
| Create `Sources/AAPowerd/PmsetControl.swift` | The two fixed `pmset` argument vectors, plus read-back. |
| Create `Sources/AAPowerd/HeldMarker.swift` | The root-owned marker used for startup reconciliation. |
| Create `Resources/dev.agentwarden.powerd.plist` | LaunchDaemon template with `Sockets` declaration. |
| Create `Scripts/install-powerd.sh` | Privileged install/uninstall of binary, plist and marker dir. |
| Modify `Package.swift` | Add the `AAPowerd` executable target and product. |
| Modify `install.sh`, `uninstall.sh` | Call `install-powerd.sh`; print the emergency repair line. |

### Phase 2 — roam itself

| File | Responsibility |
|---|---|
| Create `Sources/AgentAttentionCore/RoamState.swift` | `roam.json` model plus process-liveness validation. Pure. |
| Create `Sources/AgentAttentionCore/RoamPolicy.swift` | Battery guard decisions. Pure. |
| Create `Sources/AgentAttentionCore/RoamNetwork.swift` | Gateway → hotspot classification and the at-the-desk nudge policy. Pure. |
| Create `Sources/AgentAttentionApp/SleepAssertion.swift` | IOKit assertion take/release. |
| Create `Sources/AgentAttentionApp/SystemSleep.swift` | `IOPMSleepSystem` wrapper with a checked return. |
| Create `Sources/AgentAttentionApp/PowerLeaseClient.swift` | Long-lived socket client: hello, acquire, renew, release, EOF watch. |
| Create `Sources/AgentAttentionApp/RoamService.swift` | Orchestrates enter, exit, heartbeat, battery guard. |
| Modify `Sources/AgentAttentionCore/Paths.swift` | Add `roamFile`. |
| Modify `Sources/AgentAttentionCore/Config.swift` | Add the four roam config fields. |
| Modify `Sources/AgentAttentionApp/AppDelegate.swift` | Own `RoamService`; drive the guard from the sweep. |

### Phase 3 — the UI

| File | Responsibility |
|---|---|
| Modify `Sources/AgentAttentionCore/BubbleGeometry.swift` | `haloInset` in `frame(for:)`, `placement(for:)` and `panelFrame(...)`. |
| Modify `Sources/AgentAttentionApp/BubbleController.swift` | Child disc view, halo layer, hit-test against the disc. |
| Modify `Sources/AgentAttentionApp/BubbleMenu.swift` | The single roam menu-item constructor. |
| Modify `Sources/AgentAttentionApp/AppDelegate.swift` | Menu action, state plumbing to the bubble. |

### Phase 4 — the footer

| File | Responsibility |
|---|---|
| Create `Sources/AgentAttentionCore/RoamIndicator.swift` | The indicator string, from validated state. Pure. |
| Create `Sources/AARoam/main.swift` | `aa-roam indicator \| status \| on \| off`. |
| Create `Scripts/manage-statusline.py` | Detect, migrate and revert the statusLine wrapper. |
| Modify `Package.swift`, `install.sh`, `uninstall.sh` | Ship and wire `aa-roam`. |

---

# PHASE 1 — The privileged daemon

Ships when: `pmset -g | grep SleepDisabled` flips across acquire/release, a killed client reverts it, a `SIGSTOP`ped client reverts it after the heartbeat expires, and `acquire` refuses when the setting is already `1`.

---

### Task 1: Reading `SleepDisabled` back from `pmset`

Every privileged write is verified by reading the setting back. That read has to survive `pmset` output changing shape, so it is parsed in Core and tested against real output.

**Files:**
- Create: `Sources/AgentAttentionCore/SleepDisabled.swift`
- Test: `Tests/AgentAttentionCoreTests/SleepDisabledTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `enum SleepDisabled { case on, off, unknown }` with `static func parse(_ pmsetOutput: String) -> SleepDisabled`.

- [ ] **Step 1: Write the failing test**

Real output captured from this machine on 2026-09-09, where roam was active:

```swift
import Foundation
import Testing
@testable import AgentAttentionCore

@Suite("Reading SleepDisabled back")
struct SleepDisabledTests {

    /// Verbatim from `pmset -g` on a machine where lid-close sleep was blocked.
    private let blocked = """
    System-wide power settings:
     SleepDisabled\t\t1
    Currently in use:
     standby              1
     hibernatefile        /var/vm/sleepimage
    """

    private let free = """
    System-wide power settings:
     SleepDisabled\t\t0
    Currently in use:
     standby              1
    """

    @Test("The setting is read as itself, not inferred")
    func readsBothStates() {
        #expect(SleepDisabled.parse(blocked) == .on)
        #expect(SleepDisabled.parse(free) == .off)
    }

    /// A reading we cannot make is never reported as "off". Treating an unreadable
    /// answer as off would let the daemon claim it had cleared a setting it never saw.
    @Test("An answer we cannot read is unknown, never off", arguments: [
        "", "   ", "System-wide power settings:", "SleepDisabled", "SleepDisabled\tmaybe",
    ])
    func unreadableIsUnknown(output: String) {
        #expect(SleepDisabled.parse(output) == .unknown)
    }

    @Test("The key is matched exactly, not as a substring")
    func doesNotMatchLookalikes() {
        #expect(SleepDisabled.parse(" NotSleepDisabledReally\t1") == .unknown)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `./Scripts/test.sh --filter "Reading SleepDisabled back"`
Expected: FAIL — `cannot find 'SleepDisabled' in scope`.

- [ ] **Step 3: Write minimal implementation**

```swift
import Foundation

/// Whether the machine's global lid-close sleep block is set, as `pmset` reports it.
///
/// This exists because a privileged write that is not read back is a hope, not a fact.
/// `SleepDisabled` is a single machine-wide boolean with no notion of ownership, so the
/// only way to know a transition happened is to look. An answer we cannot parse is
/// `unknown` and never `off`: reporting a setting as cleared when we did not see it
/// cleared is exactly the lie that would leave a lid-closed Mac awake in a bag.
public enum SleepDisabled: String, Sendable, Equatable {
    case on
    case off
    case unknown

    /// Parse the output of `pmset -g`. The key appears under "System-wide power settings:"
    /// as `SleepDisabled` followed by whitespace and 0 or 1.
    public static func parse(_ pmsetOutput: String) -> SleepDisabled {
        for line in pmsetOutput.split(separator: "\n", omittingEmptySubsequences: true) {
            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            // Exactly two fields, the first of which is the key itself — not a line that
            // merely contains it.
            guard fields.count == 2, fields[0] == "SleepDisabled" else { continue }
            switch fields[1] {
            case "1": return .on
            case "0": return .off
            default: return .unknown
            }
        }
        return .unknown
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `./Scripts/test.sh --filter "Reading SleepDisabled back"`
Expected: PASS, 3 tests (one with 5 cases).

- [ ] **Step 5: Review checkpoint**

Run the full suite: `./Scripts/test.sh`
Expected: all existing tests still pass. Report the new file and the test count, then stop. **Do not commit.**

---

### Task 2: The daemon's line protocol

The wire format is parsed in Core so both ends agree by construction and both can be tested without a socket.

**Files:**
- Create: `Sources/AgentAttentionCore/PowerProtocol.swift`
- Test: `Tests/AgentAttentionCoreTests/PowerProtocolTests.swift`

**Interfaces:**
- Consumes: `SleepDisabled` (Task 1).
- Produces:
  - `enum PowerRequest: Equatable { case hello(version: Int), acquire, renew, release, status }`
    with `static func parse(_ line: String) -> PowerRequest?` and `var wire: String`.
  - `enum PowerReply: Equatable { case ok, okVersion(Int), held(secondsRemaining: Int, setting: SleepDisabled), free(setting: SleepDisabled), error(PowerError) }`
    with `static func parse(_ line: String) -> PowerReply?` and `var wire: String`.
  - `enum PowerError: String, Equatable { case busy, foreign, nolease, version, unknown, unverified, pmsetFailed }`
  - `enum PowerProtocolVersion { static let current = 1 }`

- [ ] **Step 1: Write the failing test**

```swift
import Foundation
import Testing
@testable import AgentAttentionCore

@Suite("The power daemon's line protocol")
struct PowerProtocolTests {

    @Test("Every request round-trips through the wire form", arguments: [
        PowerRequest.hello(version: 1), .acquire, .renew, .release, .status,
    ])
    func requestsRoundTrip(request: PowerRequest) {
        #expect(PowerRequest.parse(request.wire) == request)
    }

    @Test("Every reply round-trips through the wire form", arguments: [
        PowerReply.ok,
        .okVersion(1),
        .held(secondsRemaining: 42, setting: .on),
        .free(setting: .off),
        .error(.busy),
        .error(.foreign),
    ])
    func repliesRoundTrip(reply: PowerReply) {
        #expect(PowerReply.parse(reply.wire) == reply)
    }

    /// The daemon runs as root and reads this from a socket. Anything it does not
    /// recognise is refused outright — never guessed at, never partially applied.
    @Test("A line we do not recognise is not a request", arguments: [
        "", "   ", "ACQUIRE", "acquire now", "hello", "hello x", "hello 1 2",
        "release; rm -rf /", "\u{0}acquire",
    ])
    func rubbishIsRefused(line: String) {
        #expect(PowerRequest.parse(line) == nil)
    }

    @Test("A request carries no free text at all")
    func requestsHaveNoPayload() {
        // Every verb but `hello` is a bare word, and `hello` takes only an integer.
        #expect(PowerRequest.acquire.wire == "acquire")
        #expect(PowerRequest.hello(version: 1).wire == "hello 1")
        #expect(PowerRequest.parse("hello 99") == .hello(version: 99))
    }

    @Test("The version the app speaks is pinned")
    func versionIsPinned() {
        #expect(PowerProtocolVersion.current == 1)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `./Scripts/test.sh --filter "The power daemon's line protocol"`
Expected: FAIL — `cannot find 'PowerRequest' in scope`.

- [ ] **Step 3: Write minimal implementation**

```swift
import Foundation

/// The protocol version the two ends must agree on. Bumped whenever a verb or a reply
/// changes shape, so an upgraded app and a stale daemon fail loudly at `hello` rather
/// than subtly at `acquire`.
public enum PowerProtocolVersion {
    public static let current = 1
}

public enum PowerError: String, Sendable, Equatable {
    /// Another connection already holds the lease.
    case busy
    /// `SleepDisabled` was already set by something that is not us. We never take it over.
    case foreign
    /// This connection does not hold the lease it is trying to renew or release.
    case nolease
    /// Protocol version mismatch.
    case version
    /// An unparseable line.
    case unknown
    /// `pmset` returned success but the read-back did not show the expected transition.
    case unverified
    /// `pmset` itself failed to run or exited non-zero.
    case pmsetFailed
}

/// What the app may ask the root daemon to do. Deliberately five verbs and no arguments
/// beyond a version integer: the daemon runs as root, and every byte it accepts from a
/// socket is attack surface. Nothing here is ever interpolated into a command.
public enum PowerRequest: Sendable, Equatable {
    case hello(version: Int)
    case acquire
    case renew
    case release
    case status

    public var wire: String {
        switch self {
        case .hello(let version): return "hello \(version)"
        case .acquire: return "acquire"
        case .renew: return "renew"
        case .release: return "release"
        case .status: return "status"
        }
    }

    public static func parse(_ line: String) -> PowerRequest? {
        // A control character means this is not a line we wrote. Refuse before splitting.
        guard !line.unicodeScalars.contains(where: { $0.value < 0x20 }) else { return nil }
        let fields = line.split(separator: " ", omittingEmptySubsequences: true)
        switch fields.count {
        case 1:
            switch fields[0] {
            case "acquire": return .acquire
            case "renew": return .renew
            case "release": return .release
            case "status": return .status
            default: return nil
            }
        case 2:
            guard fields[0] == "hello", let version = Int(fields[1]), version > 0 else { return nil }
            return .hello(version: version)
        default:
            return nil
        }
    }
}

public enum PowerReply: Sendable, Equatable {
    case ok
    case okVersion(Int)
    case held(secondsRemaining: Int, setting: SleepDisabled)
    case free(setting: SleepDisabled)
    case error(PowerError)

    public var wire: String {
        switch self {
        case .ok: return "ok"
        case .okVersion(let version): return "ok \(version)"
        case .held(let seconds, let setting): return "held \(seconds) \(setting.rawValue)"
        case .free(let setting): return "free \(setting.rawValue)"
        case .error(let error): return "error \(error.rawValue)"
        }
    }

    public static func parse(_ line: String) -> PowerReply? {
        let fields = line.split(separator: " ", omittingEmptySubsequences: true)
        guard let head = fields.first else { return nil }
        switch (head, fields.count) {
        case ("ok", 1): return .ok
        case ("ok", 2): return Int(fields[1]).map { .okVersion($0) }
        case ("held", 3):
            guard let seconds = Int(fields[1]),
                  let setting = SleepDisabled(rawValue: String(fields[2])) else { return nil }
            return .held(secondsRemaining: seconds, setting: setting)
        case ("free", 2):
            guard let setting = SleepDisabled(rawValue: String(fields[1])) else { return nil }
            return .free(setting: setting)
        case ("error", 2):
            guard let error = PowerError(rawValue: String(fields[1])) else { return nil }
            return .error(error)
        default: return nil
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `./Scripts/test.sh --filter "The power daemon's line protocol"`
Expected: PASS, 5 tests.

- [ ] **Step 5: Review checkpoint**

Run `./Scripts/test.sh`. Report and stop. **Do not commit.**

---

### Task 3: The lease state machine

This is the safety core. It decides who holds the block, when it expires, and — critically — refuses to take a setting that is already set. It is pure: no sockets, no clock, no `pmset`. The daemon drives it.

**Files:**
- Create: `Sources/AgentAttentionCore/PowerLease.swift`
- Test: `Tests/AgentAttentionCoreTests/PowerLeaseTests.swift`

**Interfaces:**
- Consumes: `SleepDisabled` (Task 1), `PowerReply`, `PowerError` (Task 2).
- Produces:
  ```swift
  public struct PowerLease {
      public struct Decision: Equatable {
          public var reply: PowerReply
          public var effect: Effect
      }
      public enum Effect: Equatable { case none, setBlock, clearBlock }
      public static let renewInterval: TimeInterval  // 10
      public static let expiry: TimeInterval         // 45
      public init()
      public var holder: Int?                        // connection id, nil when free
      public mutating func acquire(connection: Int, observed: SleepDisabled, now: Date) -> Decision
      public mutating func renew(connection: Int, now: Date) -> Decision
      public mutating func release(connection: Int, observed: SleepDisabled) -> Decision
      public func status(now: Date, observed: SleepDisabled) -> Decision
      public mutating func disconnected(connection: Int) -> Effect
      public mutating func expireIfDue(now: Date) -> Effect
  }
  ```

- [ ] **Step 1: Write the failing test**

```swift
import Foundation
import Testing
@testable import AgentAttentionCore

/// The lease is what makes the safety claims true. Each test below is a failure that
/// would otherwise leave a lid-closed Mac awake with nobody watching.
@Suite("The sleep-block lease")
struct PowerLeaseTests {

    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    @Test("Acquiring a free block sets it and hands out the lease")
    func acquireWhenFree() {
        var lease = PowerLease()
        let decision = lease.acquire(connection: 1, observed: .off, now: t0)
        #expect(decision.reply == .ok)
        #expect(decision.effect == .setBlock)
        #expect(lease.holder == 1)
    }

    /// Verified live on 2026-09-09: `SleepDisabled` was already 1 because a separate tool
    /// had an active session. A daemon that took it over would have silently ended that
    /// session; a daemon that cleared it on exit would have ended it later and worse.
    @Test("A block somebody else already holds is refused, never taken over")
    func acquireRefusesForeignBlock() {
        var lease = PowerLease()
        let decision = lease.acquire(connection: 1, observed: .on, now: t0)
        #expect(decision.reply == .error(.foreign))
        #expect(decision.effect == .none)
        #expect(lease.holder == nil)
    }

    @Test("A reading we could not make is not treated as free")
    func acquireRefusesUnknownReading() {
        var lease = PowerLease()
        let decision = lease.acquire(connection: 1, observed: .unknown, now: t0)
        #expect(decision.reply == .error(.unverified))
        #expect(decision.effect == .none)
    }

    @Test("Only one lease exists at a time")
    func secondAcquireIsBusy() {
        var lease = PowerLease()
        _ = lease.acquire(connection: 1, observed: .off, now: t0)
        let decision = lease.acquire(connection: 2, observed: .off, now: t0)
        #expect(decision.reply == .error(.busy))
        #expect(decision.effect == .none)
        #expect(lease.holder == 1)
    }

    @Test("Only the holder may renew or release")
    func nonHolderCannotRenewOrRelease() {
        var lease = PowerLease()
        _ = lease.acquire(connection: 1, observed: .off, now: t0)
        #expect(lease.renew(connection: 2, now: t0).reply == .error(.nolease))
        #expect(lease.release(connection: 2, observed: .on).reply == .error(.nolease))
        #expect(lease.holder == 1)
    }

    /// The failure a connection-only lease misses entirely: an app that is alive, holding
    /// the socket open, but wedged — deadlocked, SIGSTOPped, or no longer running its sweep.
    @Test("A lease nobody renews expires on its own")
    func leaseExpires() {
        var lease = PowerLease()
        _ = lease.acquire(connection: 1, observed: .off, now: t0)
        #expect(lease.expireIfDue(now: t0.addingTimeInterval(44)) == .none)
        #expect(lease.expireIfDue(now: t0.addingTimeInterval(46)) == .clearBlock)
        #expect(lease.holder == nil)
    }

    @Test("Renewing pushes the deadline out")
    func renewExtends() {
        var lease = PowerLease()
        _ = lease.acquire(connection: 1, observed: .off, now: t0)
        #expect(lease.renew(connection: 1, now: t0.addingTimeInterval(30)).reply == .ok)
        #expect(lease.expireIfDue(now: t0.addingTimeInterval(70)) == .none)
        #expect(lease.expireIfDue(now: t0.addingTimeInterval(80)) == .clearBlock)
    }

    @Test("An expired lease clears the block exactly once")
    func expiryIsNotRepeated() {
        var lease = PowerLease()
        _ = lease.acquire(connection: 1, observed: .off, now: t0)
        #expect(lease.expireIfDue(now: t0.addingTimeInterval(60)) == .clearBlock)
        #expect(lease.expireIfDue(now: t0.addingTimeInterval(90)) == .none)
    }

    @Test("The holder disconnecting clears the block immediately")
    func disconnectReleases() {
        var lease = PowerLease()
        _ = lease.acquire(connection: 1, observed: .off, now: t0)
        #expect(lease.disconnected(connection: 1) == .clearBlock)
        #expect(lease.holder == nil)
    }

    /// A short-lived `status` connection must never own cleanup — otherwise every
    /// `aa-roam status` would end the roam session it was asking about.
    @Test("A connection that never held the lease releases nothing when it drops")
    func statusConnectionOwnsNothing() {
        var lease = PowerLease()
        _ = lease.acquire(connection: 1, observed: .off, now: t0)
        #expect(lease.disconnected(connection: 2) == .none)
        #expect(lease.holder == 1)
    }

    @Test("Status reports the remaining time and what was actually observed")
    func statusReportsReality() {
        var lease = PowerLease()
        _ = lease.acquire(connection: 1, observed: .off, now: t0)
        let held = lease.status(now: t0.addingTimeInterval(5), observed: .on)
        #expect(held.reply == .held(secondsRemaining: 40, setting: .on))
        var free = PowerLease()
        #expect(free.status(now: t0, observed: .off).reply == .free(setting: .off))
        _ = free
    }

    @Test("The heartbeat interval leaves room for missed beats")
    func intervalsAreSane() {
        #expect(PowerLease.renewInterval == 10)
        #expect(PowerLease.expiry == 45)
        #expect(PowerLease.expiry > PowerLease.renewInterval * 3)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `./Scripts/test.sh --filter "The sleep-block lease"`
Expected: FAIL — `cannot find 'PowerLease' in scope`.

- [ ] **Step 3: Write minimal implementation**

```swift
import Foundation

/// Who currently holds the machine's lid-close sleep block, and until when.
///
/// **Why a lease and not a flag.** The failure that actually costs something is a Mac
/// left awake with the lid shut and nobody watching: the battery goes flat and the work
/// is lost. Tying the block to a lease means the dangerous state cannot outlive the thing
/// that asked for it.
///
/// **Why the lease expires as well as dropping on disconnect.** A closed socket catches an
/// app that exited or crashed. It does not catch one that is alive but wedged —
/// deadlocked, `SIGSTOP`ped, or simply no longer running its own timers. Those are the
/// cases where the socket stays open forever, so the lease carries a deadline the holder
/// must keep pushing out.
///
/// Pure on purpose: no clock, no socket, no `pmset`. The caller supplies the time and the
/// observed setting, and applies the returned effect. That makes every rule here testable
/// without root, a machine, or a wait.
public struct PowerLease: Sendable {
    /// How often the holder is expected to renew.
    public static let renewInterval: TimeInterval = 10
    /// How long after the last renewal the lease dies. Three missed beats plus slack:
    /// long enough that a busy machine does not lose its block, short enough that a wedged
    /// app cannot flatten the battery.
    public static let expiry: TimeInterval = 45

    public enum Effect: Sendable, Equatable {
        case none
        case setBlock
        case clearBlock
    }

    public struct Decision: Sendable, Equatable {
        public var reply: PowerReply
        public var effect: Effect
        public init(reply: PowerReply, effect: Effect) {
            self.reply = reply
            self.effect = effect
        }
    }

    /// The connection holding the lease, or nil when the block is free.
    public private(set) var holder: Int?
    private var deadline: Date?

    public init() {}

    public mutating func acquire(connection: Int, observed: SleepDisabled, now: Date) -> Decision {
        if let holder, holder != connection {
            return Decision(reply: .error(.busy), effect: .none)
        }
        switch observed {
        case .on where holder == nil:
            // Somebody else's block. `SleepDisabled` has no ownership identity, so taking
            // it over would mean stealing it, and clearing it later would mean ending
            // their session. Refuse and say so.
            return Decision(reply: .error(.foreign), effect: .none)
        case .unknown:
            return Decision(reply: .error(.unverified), effect: .none)
        default:
            holder = connection
            deadline = now.addingTimeInterval(PowerLease.expiry)
            return Decision(reply: .ok, effect: .setBlock)
        }
    }

    public mutating func renew(connection: Int, now: Date) -> Decision {
        guard holder == connection else { return Decision(reply: .error(.nolease), effect: .none) }
        deadline = now.addingTimeInterval(PowerLease.expiry)
        return Decision(reply: .ok, effect: .none)
    }

    public mutating func release(connection: Int, observed: SleepDisabled) -> Decision {
        guard holder == connection else { return Decision(reply: .error(.nolease), effect: .none) }
        holder = nil
        deadline = nil
        return Decision(reply: .ok, effect: .clearBlock)
    }

    public func status(now: Date, observed: SleepDisabled) -> Decision {
        guard holder != nil, let deadline else {
            return Decision(reply: .free(setting: observed), effect: .none)
        }
        let remaining = max(0, Int(deadline.timeIntervalSince(now).rounded(.down)))
        return Decision(reply: .held(secondsRemaining: remaining, setting: observed), effect: .none)
    }

    /// A connection closed. Only the holder's closing means anything.
    public mutating func disconnected(connection: Int) -> Effect {
        guard holder == connection else { return .none }
        holder = nil
        deadline = nil
        return .clearBlock
    }

    /// Called from the daemon's own timer, which must be independent of the connection
    /// read loop — a timer driven by that loop would stop exactly when the loop hangs.
    public mutating func expireIfDue(now: Date) -> Effect {
        guard holder != nil, let deadline, now >= deadline else { return .none }
        holder = nil
        self.deadline = nil
        return .clearBlock
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `./Scripts/test.sh --filter "The sleep-block lease"`
Expected: PASS, 12 tests.

- [ ] **Step 5: Review checkpoint**

Run `./Scripts/test.sh`. Report and stop. **Do not commit.**

---

### Task 4: The daemon executable

Wires the pure pieces to launchd, a socket, and `pmset`. Little logic of its own — everything decidable already lives in Tasks 1–3.

**Files:**
- Create: `Sources/AAPowerd/main.swift`
- Create: `Sources/AAPowerd/PmsetControl.swift`
- Create: `Sources/AAPowerd/HeldMarker.swift`
- Create: `Sources/AAPowerd/PowerDaemon.swift`
- Modify: `Package.swift`

**Interfaces:**
- Consumes: `PowerLease`, `PowerRequest`, `PowerReply`, `PowerError`, `SleepDisabled`.
- Produces: an `aa-powerd` executable installed as `dev.agentwarden.powerd`.

- [ ] **Step 1: Add the target to `Package.swift`**

Add to `products`:

```swift
.executable(name: "aa-powerd", targets: ["AAPowerd"]),
```

Add to `targets`:

```swift
.executableTarget(
    name: "AAPowerd",
    dependencies: ["AgentAttentionCore"],
    swiftSettings: [.swiftLanguageMode(.v5)]
),
```

- [ ] **Step 2: Write `PmsetControl.swift`**

```swift
import Foundation
import AgentAttentionCore

/// The only privileged thing this daemon does: write and read the global `SleepDisabled`
/// setting.
///
/// Two fixed argument vectors and one read. Nothing from the socket ever reaches these —
/// there is no string to interpolate, because the protocol carries no arguments. `pmset`
/// is addressed by absolute path so `PATH` cannot redirect a root exec.
enum PmsetControl {
    static let executable = "/usr/bin/pmset"

    /// Set or clear the block, then **verify by reading it back**. A write that reports
    /// success but does not change the setting is a failure: `pmset -a disablesleep` is
    /// undocumented and unsupported, so its success is never assumed.
    static func write(_ wanted: SleepDisabled) -> PowerError? {
        guard wanted == .on || wanted == .off else { return .unverified }
        let value = wanted == .on ? "1" : "0"
        guard run([executable, "-a", "disablesleep", value]) == 0 else { return .pmsetFailed }
        return read() == wanted ? nil : .unverified
    }

    static func read() -> SleepDisabled {
        guard let output = capture([executable, "-g"]) else { return .unknown }
        return SleepDisabled.parse(output)
    }

    private static func run(_ argv: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: argv[0])
        process.arguments = Array(argv.dropFirst())
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return -1 }
        process.waitUntilExit()
        return process.terminationStatus
    }

    private static func capture(_ argv: [String]) -> String? {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: argv[0])
        process.arguments = Array(argv.dropFirst())
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
```

- [ ] **Step 3: Write `HeldMarker.swift`**

```swift
import Foundation

/// A root-owned note saying "this daemon set the block".
///
/// It exists for one moment: daemon startup. The daemon holds no lease then, but
/// `SleepDisabled` may still be `1` — either because this daemon set it and then crashed,
/// or because something else entirely owns it. Clearing it unconditionally would end a
/// stranger's session; leaving it always would strand a machine that cannot sleep. The
/// marker is the only thing that tells those two apart.
///
/// Root-owned and outside every user-writable tree, for the same reason the binary is: a
/// marker the user could write would let anyone make a root daemon clear a setting it
/// does not own.
enum HeldMarker {
    static let directory = "/Library/Application Support/dev.agentwarden"
    static let path = "/Library/Application Support/dev.agentwarden/held"

    static var exists: Bool { FileManager.default.fileExists(atPath: path) }

    /// Written only after a `setBlock` has been verified by read-back.
    static func write() {
        try? FileManager.default.createDirectory(
            atPath: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700, .ownerAccountID: 0]
        )
        FileManager.default.createFile(
            atPath: path,
            contents: Data(ISO8601DateFormatter().string(from: Date()).utf8),
            attributes: [.posixPermissions: 0o600, .ownerAccountID: 0]
        )
    }

    /// Removed *before* the block is cleared, so a crash between the two leaves the
    /// safe combination: no marker, block still set, startup declines to touch it and the
    /// operator has the documented `sudo pmset -a disablesleep 0` repair.
    static func clear() {
        try? FileManager.default.removeItem(atPath: path)
    }
}
```

- [ ] **Step 4: Write `PowerDaemon.swift`**

```swift
import Foundation
import AgentAttentionCore

/// Serves the lease over a launchd-provided socket.
///
/// The socket is declared in the LaunchDaemon plist and obtained with
/// `launch_activate_socket`, so launchd — not this process — owns the endpoint, its owner
/// and its mode. That removes every bind/unlink/stale-inode race, and it is why none of
/// `BridgeSocketServer`'s setup is reused here: its `verifyPrivateParent` requires a 0700
/// directory owned by the current process, which a shared root directory can never be.
final class PowerDaemon {
    private var lease = PowerLease()
    private let queue = DispatchQueue(label: "dev.agentwarden.powerd.state")
    private let allowedUID: uid_t
    private var nextConnectionID = 1

    init(allowedUID: uid_t) {
        self.allowedUID = allowedUID
    }

    /// Startup reconciliation. Runs before any client can be served.
    ///
    /// Holds no lease by definition, so it clears the block **only** if its own marker says
    /// it set it. No marker means somebody else owns the setting, and a root daemon that
    /// clears settings it does not own is a bug with teeth.
    func reconcile() {
        guard PmsetControl.read() == .on else { HeldMarker.clear(); return }
        guard HeldMarker.exists else {
            log("SleepDisabled is set but no marker of ours — leaving it alone")
            return
        }
        HeldMarker.clear()
        if let error = PmsetControl.write(.off) {
            log("startup revert failed: \(error.rawValue)")
        } else {
            log("reverted a block left by a previous run")
        }
    }

    /// The expiry timer. Deliberately its own timer on its own queue: a timer serviced by
    /// the connection read loop would stop firing exactly when that loop hangs, which is
    /// the failure the expiry exists to catch.
    func startExpiryTimer() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 5, repeating: 5)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.apply(self.lease.expireIfDue(now: Date()))
        }
        timer.resume()
        expiryTimer = timer
    }
    private var expiryTimer: DispatchSourceTimer?

    /// Answer one request. `connection` identifies the peer so the lease can tell the
    /// holder from a passing `status` caller.
    func handle(_ request: PowerRequest, connection: Int) -> PowerReply {
        queue.sync {
            switch request {
            case .hello(let version):
                return version == PowerProtocolVersion.current
                    ? .okVersion(PowerProtocolVersion.current)
                    : .error(.version)
            case .acquire:
                let decision = lease.acquire(connection: connection,
                                             observed: PmsetControl.read(), now: Date())
                return applyGuarded(decision, connection: connection)
            case .renew:
                return lease.renew(connection: connection, now: Date()).reply
            case .release:
                let decision = lease.release(connection: connection, observed: PmsetControl.read())
                return applyGuarded(decision, connection: connection)
            case .status:
                return lease.status(now: Date(), observed: PmsetControl.read()).reply
            }
        }
    }

    /// Apply an effect and let a failed `pmset` undo the lease bookkeeping, so the daemon's
    /// idea of the world never runs ahead of the machine's.
    private func applyGuarded(_ decision: PowerLease.Decision, connection: Int) -> PowerReply {
        switch decision.effect {
        case .none:
            return decision.reply
        case .setBlock:
            if let error = PmsetControl.write(.on) {
                _ = lease.release(connection: connection, observed: PmsetControl.read())
                return .error(error)
            }
            HeldMarker.write()
            return decision.reply
        case .clearBlock:
            HeldMarker.clear()
            if let error = PmsetControl.write(.off) { return .error(error) }
            return decision.reply
        }
    }

    private func apply(_ effect: PowerLease.Effect) {
        switch effect {
        case .none: break
        case .setBlock:
            if PmsetControl.write(.on) == nil { HeldMarker.write() }
        case .clearBlock:
            HeldMarker.clear()
            if let error = PmsetControl.write(.off) { log("revert failed: \(error.rawValue)") }
            else { log("lease ended — block cleared") }
        }
    }

    func connectionClosed(_ connection: Int) {
        queue.sync { apply(lease.disconnected(connection: connection)) }
    }

    func claimConnectionID() -> Int {
        queue.sync { defer { nextConnectionID += 1 }; return nextConnectionID }
    }

    var expectedUID: uid_t { allowedUID }

    /// Unified logging, never a file. A root daemon opening a user-writable log path is a
    /// symlink and ownership hazard.
    func log(_ message: String) {
        NSLog("[agentwarden.powerd] %@", message)
    }
}
```

- [ ] **Step 5: Write `main.swift`**

```swift
import Foundation
import AgentAttentionCore

// The UID permitted to talk to this daemon, written by the installer into a root-owned
// file. Read from there and nowhere else: a user-writable source would let anyone
// nominate themselves.
let allowedUIDPath = "/Library/Application Support/dev.agentwarden/allowed-uid"

guard let text = try? String(contentsOfFile: allowedUIDPath, encoding: .utf8),
      let uid = uid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
    NSLog("[agentwarden.powerd] no allowed-uid file — refusing to start")
    exit(1)
}

let daemon = PowerDaemon(allowedUID: uid)
daemon.reconcile()
daemon.startExpiryTimer()
daemon.log("started, serving uid \(uid)")

// Socket from launchd (`Sockets` → `PowerdSocket` in the plist). launchd created it with
// the right owner and mode before anything could connect.
var fds: UnsafeMutablePointer<Int32>?
var count: size_t = 0
guard launch_activate_socket("PowerdSocket", &fds, &count) == 0, let fds, count > 0 else {
    daemon.log("launchd did not hand over a socket — refusing to start")
    exit(1)
}
let listener = fds[0]
free(fds)

// Accept loop. One thread per connection: connections are few (the app, plus the
// occasional `aa-roam status`) and each is long-lived, so a thread each is simpler than
// multiplexing and cannot starve the expiry timer, which lives on its own queue.
while true {
    let client = accept(listener, nil, nil)
    guard client >= 0 else { continue }

    var peer: uid_t = 0
    var peerGID: gid_t = 0
    guard getpeereid(client, &peer, &peerGID) == 0, peer == daemon.expectedUID else {
        // Authenticates a *user*, not this application. Any process running as that user
        // can hold the lease; without stable code signing that cannot be tightened.
        daemon.log("refused a connection from uid \(peer)")
        close(client)
        continue
    }

    let id = daemon.claimConnectionID()
    Thread.detachNewThread {
        defer { daemon.connectionClosed(id); close(client) }
        var buffer = [UInt8](repeating: 0, count: 256)
        var pending = Data()
        while true {
            let n = read(client, &buffer, buffer.count)
            guard n > 0 else { return }             // EOF or error: the lease drops
            pending.append(contentsOf: buffer[0..<n])
            guard pending.count < 4096 else { return }   // bounded: no unbounded growth
            while let newline = pending.firstIndex(of: 0x0A) {
                let line = String(decoding: pending[pending.startIndex..<newline], as: UTF8.self)
                pending.removeSubrange(pending.startIndex...newline)
                let reply: PowerReply = PowerRequest.parse(line)
                    .map { daemon.handle($0, connection: id) } ?? .error(.unknown)
                let out = Data((reply.wire + "\n").utf8)
                _ = out.withUnsafeBytes { write(client, $0.baseAddress, out.count) }
            }
        }
    }
}
```

- [ ] **Step 6: Verify it builds**

Run: `swift build 2>&1 | tail -20`
Expected: `Build complete!` with no errors in `AAPowerd`.

- [ ] **Step 7: Review checkpoint**

Run `./Scripts/test.sh`. Report the new target and that the daemon compiles. It is not installed yet — that is Task 5. Stop. **Do not commit.**

---

### Task 5: Installing the daemon

The security-critical step. Everything here is about the binary and its inputs living where the installing user cannot write them.

**Files:**
- Create: `Resources/dev.agentwarden.powerd.plist`
- Create: `Scripts/install-powerd.sh`
- Modify: `install.sh`, `uninstall.sh`

**Interfaces:**
- Consumes: the `aa-powerd` binary from Task 4.
- Produces: a running LaunchDaemon and the socket at `/var/run/dev.agentwarden.powerd.sock`.

- [ ] **Step 1: Write the plist template**

`Resources/dev.agentwarden.powerd.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>dev.agentwarden.powerd</string>
    <key>Program</key>
    <string>/Library/PrivilegedHelperTools/dev.agentwarden.powerd</string>
    <key>KeepAlive</key>
    <true/>
    <key>Sockets</key>
    <dict>
        <key>PowerdSocket</key>
        <dict>
            <key>SockPathName</key>
            <string>/var/run/dev.agentwarden.powerd.sock</string>
            <key>SockPathOwner</key>
            <integer>__UID__</integer>
            <key>SockPathMode</key>
            <integer>384</integer>
        </dict>
    </dict>
</dict>
</plist>
```

`384` is decimal for `0600`. `__UID__` is replaced by the installer with the installing user's numeric UID, so launchd creates the socket already owned by them.

- [ ] **Step 2: Write `Scripts/install-powerd.sh`**

```bash
#!/bin/bash
# Install or remove the Agent Warden power helper.
#
# The helper runs as root, so every input it touches must be somewhere the installing
# user cannot write. A root daemon executing a user-writable binary is arbitrary root
# execution for anyone who can write that file — and this project's normal homes
# (build/, ~/Applications, ~/.local/bin) are all user-writable. Hence /Library.
#
# Usage:  install-powerd.sh install <path-to-aa-powerd>
#         install-powerd.sh uninstall
set -euo pipefail

LABEL="dev.agentwarden.powerd"
HELPER="/Library/PrivilegedHelperTools/$LABEL"
PLIST="/Library/LaunchDaemons/$LABEL.plist"
SUPPORT="/Library/Application Support/dev.agentwarden"
SOCKET="/var/run/$LABEL.sock"
TEMPLATE="$(cd "$(dirname "$0")/.." && pwd)/Resources/$LABEL.plist"

case "${1:-}" in
install)
  SRC="${2:?usage: install-powerd.sh install <path-to-aa-powerd>}"
  [ -x "$SRC" ] || { echo "not executable: $SRC" >&2; exit 1; }
  UID_NUM="$(id -u)"

  echo "Installing the power helper. This needs your password once."
  sudo mkdir -p /Library/PrivilegedHelperTools "$SUPPORT"
  sudo chown root:wheel /Library/PrivilegedHelperTools "$SUPPORT"
  sudo chmod 755 /Library/PrivilegedHelperTools
  sudo chmod 700 "$SUPPORT"

  # Atomic replace, then ownership, then load — never the other way round.
  sudo cp "$SRC" "$HELPER.new"
  sudo chown root:wheel "$HELPER.new"
  sudo chmod 755 "$HELPER.new"
  sudo mv -f "$HELPER.new" "$HELPER"

  printf '%s\n' "$UID_NUM" | sudo tee "$SUPPORT/allowed-uid" >/dev/null
  sudo chown root:wheel "$SUPPORT/allowed-uid"
  sudo chmod 600 "$SUPPORT/allowed-uid"

  sed "s/__UID__/$UID_NUM/" "$TEMPLATE" | sudo tee "$PLIST" >/dev/null
  sudo chown root:wheel "$PLIST"
  sudo chmod 644 "$PLIST"

  sudo launchctl bootout system/"$LABEL" 2>/dev/null || true
  sudo launchctl bootstrap system "$PLIST"
  echo "Installed. Socket: $SOCKET"
  echo
  echo "If roam ever leaves your Mac unable to sleep, the repair is:"
  echo "    sudo pmset -a disablesleep 0"
  ;;
uninstall)
  echo "Removing the power helper. This needs your password once."
  # Release before removing the thing that would have released it.
  sudo launchctl bootout system/"$LABEL" 2>/dev/null || true
  sudo pmset -a disablesleep 0 || true
  # Fixed constants only. Never a path read from install-manifest.json, which is
  # user-writable and would otherwise be a root-deletion primitive.
  sudo rm -f "$HELPER" "$PLIST" "$SUPPORT/allowed-uid" "$SUPPORT/held" "$SOCKET"
  sudo rmdir "$SUPPORT" 2>/dev/null || true
  if [ "$(pmset -g | awk '/SleepDisabled/ {print $2}')" != "0" ]; then
    echo "WARNING: SleepDisabled is still set. Run: sudo pmset -a disablesleep 0" >&2
  fi
  echo "Removed."
  ;;
*)
  echo "usage: install-powerd.sh {install <path>|uninstall}" >&2
  exit 64
  ;;
esac
```

- [ ] **Step 3: Make it executable and wire it into `install.sh`**

```bash
chmod +x Scripts/install-powerd.sh
```

In `install.sh`, after the "Wiring Claude Code hooks" section, add:

```bash
echo "== Power helper (needed for lid-closed roam) =="
if [ -n "$DRY_RUN" ]; then
  echo "would install $LABEL from $APP/Contents/MacOS/aa-powerd"
else
  bash "$ROOT/Scripts/install-powerd.sh" install "$APP/Contents/MacOS/aa-powerd"
fi
```

In `uninstall.sh`, before the hook removal, add:

```bash
bash "$ROOT/Scripts/install-powerd.sh" uninstall || true
```

- [ ] **Step 4: Confirm `build-app.sh` ships the binary**

`Scripts/build-app.sh` copies the built executables into `AgentWarden.app/Contents/MacOS/`. Confirm `aa-powerd` is included; if the script enumerates names explicitly, add it there.

Run: `./Scripts/build-app.sh 2>&1 | tail -5` then `ls build/AgentWarden.app/Contents/MacOS/`
Expected: `aa-powerd` present.

> **Note for the executor:** `build-app.sh` also installs and restarts the running app. That is expected here, but say so in your report — it changes the user's live tooling.

- [ ] **Step 5: Install and verify the daemon by hand**

```bash
bash Scripts/install-powerd.sh install build/AgentWarden.app/Contents/MacOS/aa-powerd
ls -l@ /var/run/dev.agentwarden.powerd.sock
sudo launchctl print system/dev.agentwarden.powerd | head -20
```

Expected: the socket exists, owned by the installing user, mode `srw-------`; the service is loaded.

- [ ] **Step 6: Exercise the lease by hand**

With `nc -U`, one connection at a time:

```bash
# Acquire and hold. Leave this running in one terminal.
printf 'hello 1\nacquire\n' | nc -U /var/run/dev.agentwarden.powerd.sock
```

In a second terminal, check each of these:

| Check | Command | Expected |
|---|---|---|
| Block is set while held | `pmset -g \| grep SleepDisabled` | `1` |
| Block clears on disconnect | kill the `nc`, wait 1s, re-check | `0` |
| Expiry catches a wedged holder | acquire, then `SIGSTOP` the `nc`, wait 50s | `0` |
| Foreign block is refused | `sudo pmset -a disablesleep 1`, then acquire | `error foreign` |
| Second acquire is refused | acquire on two connections | `error busy` |
| Version mismatch is loud | `printf 'hello 99\n' \| nc -U …` | `error version` |

Reset afterwards: `sudo pmset -a disablesleep 0`.

- [ ] **Step 7: Review checkpoint**

Report each row of that table with its actual observed output. **Phase 1 ships here.** Stop. **Do not commit.**

---

# PHASE 2 — Roam itself

Ships when: roam enters from a test harness, the lid can be closed without the machine sleeping, and a forced low-battery reading exits roam and sleeps the Mac in the right order.

---

### Task 6: `roam.json` and its liveness rule

A static file cannot express "true only while a process lives". A `SIGKILL` skips `applicationWillTerminate`, and the footer would keep printing `🎒 roam on` after both protections were gone. So the file carries the owning process fingerprint and is validated on every read — the same trick `pairings.json` already uses for Claude processes.

**Files:**
- Create: `Sources/AgentAttentionCore/RoamState.swift`
- Modify: `Sources/AgentAttentionCore/Paths.swift`
- Test: `Tests/AgentAttentionCoreTests/RoamStateTests.swift`

**Interfaces:**
- Consumes: `ProcessFingerprint` (existing, in `TerminalPairing.swift`).
- Produces:
  - `struct RoamState: Codable, Sendable, Equatable` with `schema`, `active`, `startedAt`, `ownerPID`, `ownerPIDStartedAt`, `leaseRenewedAt`, `enteredOnBattery`, `hotspot: RoamHotspot?`, `nudgeSnoozedUntil`.
  - `func isLive(now:leaseWindow:probe:) -> Bool`
  - `struct RoamHotspot: Codable, Sendable, Equatable { var kind: String; var ssid: String? }`
  - `AppPaths.roamFile`

- [ ] **Step 1: Write the failing test**

```swift
import Foundation
import Testing
@testable import AgentAttentionCore

@Suite("Roam state and whether it is still true")
struct RoamStateTests {

    private let t0 = Date(timeIntervalSince1970: 2_000_000)

    private func state(pid: Int32 = 4711, started: Double = 500,
                       renewed: Date? = nil) -> RoamState {
        RoamState(active: true, startedAt: t0, ownerPID: pid, ownerPIDStartedAt: started,
                  leaseRenewedAt: renewed ?? t0, enteredOnBattery: false,
                  hotspot: RoamHotspot(kind: "iphone", ssid: "phone"), nudgeSnoozedUntil: nil)
    }

    /// The owner is alive and the lease is fresh: roam really is on.
    @Test("Live owner plus a fresh lease reads as active")
    func liveAndFresh() {
        let live = state()
        #expect(live.isLive(now: t0.addingTimeInterval(5), leaseWindow: 45,
                           probe: { _ in 500 }))
    }

    /// The bug this closes: SIGKILL leaves the file behind, and the footer would keep
    /// claiming the lid was safe to close long after nothing was holding it open.
    @Test("A dead owner reads as inactive, whatever the file says")
    func deadOwnerIsNotActive() {
        #expect(!state().isLive(now: t0, leaseWindow: 45, probe: { _ in nil }))
    }

    /// A recycled PID is a different process. Matching on the number alone would adopt
    /// a stranger's process as the owner of a roam session.
    @Test("A recycled PID is not the same owner")
    func recycledPIDIsNotTheOwner() {
        #expect(!state().isLive(now: t0, leaseWindow: 45, probe: { _ in 9_999 }))
    }

    @Test("A lease nobody has renewed reads as inactive")
    func staleLeaseIsNotActive() {
        let stale = state(renewed: t0)
        #expect(!stale.isLive(now: t0.addingTimeInterval(46), leaseWindow: 45,
                              probe: { _ in 500 }))
    }

    @Test("A file that says inactive is inactive regardless of liveness")
    func inactiveIsInactive() {
        var off = state()
        off.active = false
        #expect(!off.isLive(now: t0, leaseWindow: 45, probe: { _ in 500 }))
    }

    @Test("State round-trips through JSON")
    func roundTrips() throws {
        let encoded = try JSONCoding.encoder.encode(state())
        #expect(try JSONCoding.decoder.decode(RoamState.self, from: encoded) == state())
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `./Scripts/test.sh --filter "Roam state and whether it is still true"`
Expected: FAIL — `cannot find 'RoamState' in scope`.

- [ ] **Step 3: Write minimal implementation**

Create `Sources/AgentAttentionCore/RoamState.swift`:

```swift
import Foundation

/// Which phone hotspot roam believes it is on, as of entry.
public struct RoamHotspot: Codable, Sendable, Equatable {
    public var kind: String
    public var ssid: String?
    public init(kind: String, ssid: String? = nil) {
        self.kind = kind
        self.ssid = ssid
    }
}

/// What roam has on disk, so a status line and a CLI can answer without asking the app.
///
/// **A file cannot say "while I am alive".** Roam is only real while a live process holds
/// an idle assertion and a renewed lease; a `SIGKILL` skips every cleanup path and leaves
/// this file behind saying roam is on when nothing at all is holding the machine awake.
/// So the file is stamped with the owner's process fingerprint and the last lease renewal,
/// and every reader validates both. The same fingerprint trick guards `pairings.json`
/// against recycled PIDs, for the same reason: a PID on its own is reused within hours.
///
/// The file exists **if and only if** roam is fully established — assertion held, lease
/// acquired, and `SleepDisabled` verified. There is no half-entered state to describe.
public struct RoamState: Codable, Sendable, Equatable {
    public static let currentSchema = 1

    public var schema: Int
    public var active: Bool
    public var startedAt: Date
    public var ownerPID: Int32
    public var ownerPIDStartedAt: Double
    public var leaseRenewedAt: Date
    public var enteredOnBattery: Bool
    public var hotspot: RoamHotspot?
    public var nudgeSnoozedUntil: Date?

    public init(schema: Int = RoamState.currentSchema, active: Bool, startedAt: Date,
                ownerPID: Int32, ownerPIDStartedAt: Double, leaseRenewedAt: Date,
                enteredOnBattery: Bool, hotspot: RoamHotspot? = nil,
                nudgeSnoozedUntil: Date? = nil) {
        self.schema = schema
        self.active = active
        self.startedAt = startedAt
        self.ownerPID = ownerPID
        self.ownerPIDStartedAt = ownerPIDStartedAt
        self.leaseRenewedAt = leaseRenewedAt
        self.enteredOnBattery = enteredOnBattery
        self.hotspot = hotspot
        self.nudgeSnoozedUntil = nudgeSnoozedUntil
    }

    /// Is this state still true right now?
    ///
    /// - Parameter probe: returns the start time of the given PID, or nil if no such
    ///   process. Injected so the rule can be exercised without a real process.
    public func isLive(now: Date = Date(), leaseWindow: TimeInterval = 45,
                       probe: (Int32) -> Double?) -> Bool {
        guard active else { return false }
        guard let started = probe(ownerPID) else { return false }
        // Same tolerance as ProcessFingerprint: a start time a second or two apart is the
        // same process; anything else is a recycled PID wearing its number.
        guard abs(started - ownerPIDStartedAt) <= 2.0 else { return false }
        return now.timeIntervalSince(leaseRenewedAt) <= leaseWindow
    }
}
```

In `Sources/AgentAttentionCore/Paths.swift`, beside `pairingsFile`:

```swift
    /// Roam's own state. Warden's data directory, never `~/.claude/roam` — roam here is
    /// independent of the plugin it replaces.
    public var roamFile: URL { root.appendingPathComponent("roam.json") }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `./Scripts/test.sh --filter "Roam state and whether it is still true"`
Expected: PASS, 6 tests.

- [ ] **Step 5: Review checkpoint**

Run `./Scripts/test.sh`. Report and stop. **Do not commit.**

---

### Task 7: The battery guard policy

Pure decision, so the ordering the spec insists on is testable without draining a battery.

**Files:**
- Create: `Sources/AgentAttentionCore/RoamPolicy.swift`
- Test: `Tests/AgentAttentionCoreTests/RoamPolicyTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `struct PowerReading: Sendable, Equatable { var percent: Int?; var onAC: Bool }`
  - `enum RoamGuardAction: Sendable, Equatable { case none, exitAndSleep(percent: Int) }`
  - `enum RoamPolicy { static func guardAction(reading:threshold:roamActive:) -> RoamGuardAction }`

- [ ] **Step 1: Write the failing test**

```swift
import Foundation
import Testing
@testable import AgentAttentionCore

@Suite("The roam battery guard")
struct RoamPolicyTests {

    private func act(_ percent: Int?, onAC: Bool = false, active: Bool = true,
                     threshold: Int = 10) -> RoamGuardAction {
        RoamPolicy.guardAction(reading: PowerReading(percent: percent, onAC: onAC),
                               threshold: threshold, roamActive: active)
    }

    @Test("At or below the threshold on battery, roam exits and the Mac sleeps")
    func firesAtThreshold() {
        #expect(act(10) == .exitAndSleep(percent: 10))
        #expect(act(3) == .exitAndSleep(percent: 3))
    }

    @Test("Above the threshold, nothing happens")
    func quietAboveThreshold() {
        #expect(act(11) == .none)
        #expect(act(100) == .none)
    }

    /// On AC there is nothing to guard against — the whole point of the threshold is to
    /// save work before the charge runs out.
    @Test("On AC power the guard never fires")
    func neverOnAC() {
        #expect(act(5, onAC: true) == .none)
        #expect(act(1, onAC: true) == .none)
    }

    @Test("With roam off there is nothing to exit")
    func nothingToGuardWhenOff() {
        #expect(act(1, active: false) == .none)
    }

    /// A battery we cannot read is not an empty battery. Sleeping the machine on a
    /// missing reading would be worse than the thing it is protecting against.
    @Test("An unreadable battery does not trigger a sleep")
    func unknownBatteryIsNotEmpty() {
        #expect(act(nil) == .none)
    }

    @Test("A nonsensical threshold cannot make the guard fire constantly")
    func thresholdIsClamped() {
        #expect(act(50, threshold: 200) == .none)
        #expect(act(50, threshold: -5) == .none)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `./Scripts/test.sh --filter "The roam battery guard"`
Expected: FAIL — `cannot find 'RoamPolicy' in scope`.

- [ ] **Step 3: Write minimal implementation**

```swift
import Foundation

/// What the machine's power situation is right now.
public struct PowerReading: Sendable, Equatable {
    /// Battery percentage, or nil when it cannot be read. Nil is *not* zero.
    public var percent: Int?
    public var onAC: Bool
    public init(percent: Int?, onAC: Bool) {
        self.percent = percent
        self.onAC = onAC
    }
}

public enum RoamGuardAction: Sendable, Equatable {
    case none
    /// Exit roam and put the machine to sleep deliberately, while there is still charge.
    case exitAndSleep(percent: Int)
}

/// When roam should end itself.
///
/// The promise roam makes is "close the lid and your work survives". The way that promise
/// is broken is a flat battery, so the guard exists to spend the last of the charge on a
/// clean sleep rather than a hard stop.
///
/// Pure, because the alternative way to test it is to flatten a battery. The caller reads
/// the machine and applies the action.
public enum RoamPolicy {
    /// Sane bounds for a hand-edited config. A threshold of 200 would fire on every tick.
    public static let thresholdRange = 1...50

    public static func guardAction(reading: PowerReading, threshold: Int,
                                   roamActive: Bool) -> RoamGuardAction {
        guard roamActive, !reading.onAC else { return .none }
        // A battery we cannot read is not an empty one. Sleeping the machine because a
        // reading failed would cause exactly the interruption the guard exists to avoid.
        guard let percent = reading.percent else { return .none }
        guard thresholdRange.contains(threshold) else { return .none }
        return percent <= threshold ? .exitAndSleep(percent: percent) : .none
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `./Scripts/test.sh --filter "The roam battery guard"`
Expected: PASS, 6 tests.

- [ ] **Step 5: Review checkpoint**

Run `./Scripts/test.sh`. Report and stop. **Do not commit.**

---

### Task 8: Hotspot classification and the at-the-desk nudge

**Files:**
- Create: `Sources/AgentAttentionCore/RoamNetwork.swift`
- Test: `Tests/AgentAttentionCoreTests/RoamNetworkTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `enum HotspotKind: String, Sendable { case iphone, android, windows, ordinary, offline }`
  - `enum RoamNetwork { static func classify(gateway: String?) -> HotspotKind }`
  - `struct DeskReading: Sendable { var lidOpen: Bool; var hidIdleSeconds: Int; var roamAge: TimeInterval }`
  - `enum NudgePolicy { static func shouldNudge(_:snoozedUntil:now:) -> Bool }`

- [ ] **Step 1: Write the failing test**

```swift
import Foundation
import Testing
@testable import AgentAttentionCore

@Suite("Reading the network roam is on")
struct RoamNetworkTests {

    @Test("A phone hotspot is recognised by its gateway", arguments: [
        ("172.20.10.1", HotspotKind.iphone),
        ("172.20.10.14", .iphone),
        ("192.168.43.1", .android),
        ("192.168.137.1", .windows),
    ])
    func recognisesHotspots(gateway: String, expected: HotspotKind) {
        #expect(RoamNetwork.classify(gateway: gateway) == expected)
    }

    /// Read live from this machine on 2026-09-09: an ordinary home network, which is
    /// exactly the case that should produce a warning before the lid closes.
    @Test("An ordinary network is not a hotspot")
    func ordinaryNetwork() {
        #expect(RoamNetwork.classify(gateway: "192.168.2.1") == .ordinary)
        #expect(RoamNetwork.classify(gateway: "10.0.0.1") == .ordinary)
    }

    @Test("No gateway means offline, not ordinary")
    func offline() {
        #expect(RoamNetwork.classify(gateway: nil) == .offline)
        #expect(RoamNetwork.classify(gateway: "") == .offline)
        #expect(RoamNetwork.classify(gateway: "   ") == .offline)
    }

    /// The ranges are prefixes, not substrings. `9192.168.43.1` is not an Android hotspot.
    @Test("A lookalike address is not a hotspot")
    func lookalikesAreOrdinary() {
        #expect(RoamNetwork.classify(gateway: "9192.168.43.1") == .ordinary)
        #expect(RoamNetwork.classify(gateway: "192.168.430.1") == .ordinary)
    }
}

@Suite("The at-the-desk nudge")
struct NudgePolicyTests {

    private let now = Date(timeIntervalSince1970: 3_000_000)

    private func reading(lidOpen: Bool = true, idle: Int = 5,
                         age: TimeInterval = 600) -> DeskReading {
        DeskReading(lidOpen: lidOpen, hidIdleSeconds: idle, roamAge: age)
    }

    @Test("Lid open, recently typing, roam on a while — worth asking")
    func nudgesWhenClearlyAtTheDesk() {
        #expect(NudgePolicy.shouldNudge(reading(), snoozedUntil: nil, now: now))
    }

    /// Every one of these on its own is an ordinary state, not evidence. Nagging on a
    /// closed lid, or thirty seconds after entering roam, is how a helpful prompt becomes
    /// something people turn off.
    @Test("Any single missing signal means no nudge")
    func staysQuietWithoutAllThree() {
        #expect(!NudgePolicy.shouldNudge(reading(lidOpen: false), snoozedUntil: nil, now: now))
        #expect(!NudgePolicy.shouldNudge(reading(idle: 600), snoozedUntil: nil, now: now))
        #expect(!NudgePolicy.shouldNudge(reading(age: 30), snoozedUntil: nil, now: now))
    }

    @Test("A dismissed nudge stays dismissed for its window")
    func respectsSnooze() {
        let until = now.addingTimeInterval(300)
        #expect(!NudgePolicy.shouldNudge(reading(), snoozedUntil: until, now: now))
        #expect(NudgePolicy.shouldNudge(reading(), snoozedUntil: until,
                                        now: until.addingTimeInterval(1)))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `./Scripts/test.sh --filter "Reading the network roam is on"`
Expected: FAIL — `cannot find 'RoamNetwork' in scope`.

- [ ] **Step 3: Write minimal implementation**

```swift
import Foundation

/// What sort of network roam is running over.
public enum HotspotKind: String, Sendable, Equatable {
    case iphone, android, windows, ordinary, offline

    public var isHotspot: Bool {
        self == .iphone || self == .android || self == .windows
    }

    public var label: String {
        switch self {
        case .iphone: return "iPhone Personal Hotspot"
        case .android: return "Android hotspot"
        case .windows: return "Windows Mobile Hotspot"
        case .ordinary: return "an ordinary network"
        case .offline: return "no network"
        }
    }
}

/// Telling "you are tethered to your phone" from "you are on the café's Wi-Fi and will
/// lose it at the door".
///
/// **The gateway is the primary signal, and the SSID is best-effort.** Reading the gateway
/// needs no permission at all; SSID access is increasingly privacy-gated on modern macOS
/// and Apple has been closing the command-line routes since macOS 14. So nothing here may
/// depend on a name — an unreadable SSID makes the warning vaguer, never absent.
///
/// These ranges are heuristics and are documented as such: Android vendors vary, USB
/// tethering matches none of them, and IPv6-only routes exist. That is tolerable because
/// this drives a *warning* and never a block. Being wrong costs a sentence, not a session.
public enum RoamNetwork {
    public static func classify(gateway: String?) -> HotspotKind {
        guard let gateway = gateway?.trimmingCharacters(in: .whitespacesAndNewlines),
              !gateway.isEmpty else { return .offline }
        // Prefix match on a whole dotted octet, so "9192.168.43.1" cannot pass as one.
        let octets = gateway.split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4 else { return .ordinary }
        switch (octets[0], octets[1], octets[2]) {
        case ("172", "20", "10"): return .iphone
        case ("192", "168", "43"): return .android
        case ("192", "168", "137"): return .windows
        default: return .ordinary
        }
    }
}

/// What the machine looks like when somebody may have come back to it.
public struct DeskReading: Sendable, Equatable {
    public var lidOpen: Bool
    public var hidIdleSeconds: Int
    public var roamAge: TimeInterval
    public init(lidOpen: Bool, hidIdleSeconds: Int, roamAge: TimeInterval) {
        self.lidOpen = lidOpen
        self.hidIdleSeconds = hidIdleSeconds
        self.roamAge = roamAge
    }
}

/// Whether to ask "you seem to be at the desk — still need roam?".
///
/// All three signals are required together, because each on its own is an ordinary state.
/// An open lid means nothing during a coffee break; recent typing means nothing thirty
/// seconds after entering roam. A prompt that fires on one signal is a prompt people
/// silence, and a silenced prompt protects nobody.
public enum NudgePolicy {
    /// Typing within this long counts as "somebody is here".
    public static let activeWithinSeconds = 120
    /// Roam must have been on at least this long before the question is worth asking.
    public static let settleSeconds: TimeInterval = 300

    public static func shouldNudge(_ reading: DeskReading, snoozedUntil: Date?,
                                   now: Date = Date()) -> Bool {
        if let snoozedUntil, now <= snoozedUntil { return false }
        guard reading.lidOpen else { return false }
        guard reading.hidIdleSeconds <= activeWithinSeconds else { return false }
        return reading.roamAge >= settleSeconds
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `./Scripts/test.sh --filter "Reading the network roam is on"` then `./Scripts/test.sh --filter "The at-the-desk nudge"`
Expected: PASS, 4 tests and 3 tests.

- [ ] **Step 5: Review checkpoint**

Run `./Scripts/test.sh`. Report and stop. **Do not commit.**

---

### Task 9: The app-side edges — assertion, sleep, lease client

Thin wrappers over IOKit and the socket. No policy: everything decidable is already in Tasks 1–8. Not unit-testable (executable target, real system calls), so they are kept as small as possible and verified by hand in Task 10.

**Files:**
- Create: `Sources/AgentAttentionApp/SleepAssertion.swift`
- Create: `Sources/AgentAttentionApp/SystemSleep.swift`
- Create: `Sources/AgentAttentionApp/PowerLeaseClient.swift`

**Interfaces:**
- Consumes: `PowerRequest`, `PowerReply`, `PowerError`, `PowerProtocolVersion`, `PowerLease.renewInterval`.
- Produces:
  - `final class SleepAssertion { func take() -> Bool; func release() }`
  - `enum SystemSleep { static func now() -> Bool }`
  - `final class PowerLeaseClient` with `func acquire() -> Result<Void, PowerError>`, `func release() -> Bool`, `var onLost: (() -> Void)?`, and an internal 10-second renew timer.

- [ ] **Step 1: Write `SleepAssertion.swift`**

```swift
import Foundation
import IOKit.pwr_mgt

/// Keeps the machine from sleeping because nobody has touched it.
///
/// **Idle sleep only.** An earlier draft also asserted display sleep; that is wrong for
/// roam. The lid is shut, so the display is off anyway, and holding it awake would spend
/// battery on a screen nobody can see.
///
/// This replaces forking `caffeinate`. The assertion dies with the process, which is the
/// safe failure — a stray `caffeinate` outlives its owner and keeps a machine awake with
/// nothing watching it — and it leaves no child process to reap.
///
/// Assertions are advisory: macOS may override them under thermal or low-power emergency.
/// Nothing here assumes otherwise.
final class SleepAssertion {
    private var identifier: IOPMAssertionID = IOPMAssertionID(0)
    private(set) var held = false

    @discardableResult
    func take() -> Bool {
        guard !held else { return true }
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "Agent Warden roam" as CFString,
            &identifier
        )
        held = (result == kIOReturnSuccess)
        return held
    }

    func release() {
        guard held else { return }
        IOPMAssertionRelease(identifier)
        held = false
    }

    deinit { release() }
}
```

- [ ] **Step 2: Write `SystemSleep.swift`**

```swift
import Foundation
import IOKit
import IOKit.pwr_mgt

/// Put the machine to sleep deliberately.
///
/// **This needs no privilege escalation.** An earlier revision of the design claimed
/// `IOPMSleepSystem` requires root and substituted an AppleScript `System Events` sleep.
/// That was wrong on both counts. The SDK header is explicit:
///
/// > "For security purposes, caller must be root or the console user."
///
/// Agent Warden runs as the console user. The AppleScript route, by contrast, is gated by
/// Automation/TCC, which can be denied, revoked, or waiting on a consent dialog that
/// nobody can answer when the lid is closed — precisely the moment this is needed.
///
/// The return code is checked rather than assumed: under fast user switching the app may
/// no longer be the console user, and a refusal must be reported, not papered over.
enum SystemSleep {
    @discardableResult
    static func now() -> Bool {
        let port = IOPMFindPowerManagement(mach_port_t(MACH_PORT_NULL))
        guard port != IO_OBJECT_NULL else { return false }
        defer { IOServiceClose(port) }
        return IOPMSleepSystem(port) == kIOReturnSuccess
    }
}
```

- [ ] **Step 3: Write `PowerLeaseClient.swift`**

```swift
import Foundation
import AgentAttentionCore

/// The app's end of the lease: one long-lived connection to the root daemon.
///
/// Long-lived on purpose, and therefore **not** `BridgeSocketClient`, which is explicitly
/// one-shot and closes its descriptor before returning. Four of `BridgeSocket`'s
/// assumptions are inverted here anyway: it expects the peer's UID to equal its own, and
/// here the peer is root.
///
/// Two things end a lease. The connection closing covers an app that exited or crashed.
/// The heartbeat covers the case a closed socket cannot see — an app that is alive but
/// wedged, holding the socket open with nobody minding the battery.
final class PowerLeaseClient {
    static let socketPath = "/var/run/dev.agentwarden.powerd.sock"

    /// Called on the main thread when the lease is lost for any reason other than our own
    /// release: daemon death, EOF, or a refused renewal. Never a silent degradation.
    var onLost: (() -> Void)?

    private var fd: Int32 = -1
    private var renewTimer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "dev.agentwarden.roam.lease")
    private(set) var holding = false

    func acquire() -> Result<Void, PowerError> {
        guard connect() else { return .failure(.pmsetFailed) }
        switch send(.hello(version: PowerProtocolVersion.current)) {
        case .okVersion: break
        case .error(let error): disconnect(); return .failure(error)
        default: disconnect(); return .failure(.unknown)
        }
        switch send(.acquire) {
        case .ok:
            holding = true
            startRenewing()
            return .success(())
        case .error(let error): disconnect(); return .failure(error)
        default: disconnect(); return .failure(.unknown)
        }
    }

    @discardableResult
    func release() -> Bool {
        guard holding else { return true }
        let ok = send(.release) == .ok
        holding = false
        disconnect()
        return ok
    }

    /// Peer must be root. The mirror of the daemon's own check, and the reason
    /// `BridgeSocketClient` cannot be reused: it requires the peer UID to equal our own.
    private func connect() -> Bool {
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        _ = withUnsafeMutablePointer(to: &address.sun_path) { path in
            PowerLeaseClient.socketPath.withCString { source in
                strncpy(UnsafeMutableRawPointer(path).assumingMemoryBound(to: CChar.self),
                        source, MemoryLayout.size(ofValue: address.sun_path) - 1)
            }
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, size) }
        }
        guard connected == 0 else { disconnect(); return false }
        var peer: uid_t = 0
        var group: gid_t = 0
        guard getpeereid(fd, &peer, &group) == 0, peer == 0 else { disconnect(); return false }
        return true
    }

    private func disconnect() {
        renewTimer?.cancel()
        renewTimer = nil
        if fd >= 0 { close(fd); fd = -1 }
    }

    private func startRenewing() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + PowerLease.renewInterval,
                       repeating: PowerLease.renewInterval)
        timer.setEventHandler { [weak self] in
            guard let self, self.holding else { return }
            if self.send(.renew) != .ok {
                self.holding = false
                self.disconnect()
                DispatchQueue.main.async { self.onLost?() }
            }
        }
        timer.resume()
        renewTimer = timer
    }

    private func send(_ request: PowerRequest) -> PowerReply {
        guard fd >= 0 else { return .error(.unknown) }
        let out = Data((request.wire + "\n").utf8)
        let written = out.withUnsafeBytes { write(fd, $0.baseAddress, out.count) }
        guard written == out.count else { return .error(.unknown) }
        var buffer = [UInt8](repeating: 0, count: 256)
        let n = read(fd, &buffer, buffer.count)
        guard n > 0 else { return .error(.unknown) }
        let line = String(decoding: buffer[0..<n], as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return PowerReply.parse(line) ?? .error(.unknown)
    }
}
```

- [ ] **Step 4: Verify it builds**

Run: `swift build 2>&1 | tail -20`
Expected: `Build complete!`

- [ ] **Step 5: Review checkpoint**

Run `./Scripts/test.sh`. Report and stop. **Do not commit.**

---

### Task 10: `RoamService` and config

Wires Tasks 6–9 together and hangs the guard off the existing sweep.

**Files:**
- Create: `Sources/AgentAttentionApp/RoamService.swift`
- Modify: `Sources/AgentAttentionCore/Config.swift`
- Modify: `Sources/AgentAttentionApp/AppDelegate.swift`
- Test: `Tests/AgentAttentionCoreTests/SoundAndSettingsTests.swift` (extend for config defaults)

**Interfaces:**
- Consumes: everything from Tasks 6–9.
- Produces: `final class RoamService` with `func enter() -> Result<Void, PowerError>`, `func exit()`, `var isActive: Bool`, `func tick(reading: PowerReading)`, `var onChange: (() -> Void)?`.

- [ ] **Step 1: Add the config fields**

In `Sources/AgentAttentionCore/Config.swift` add four stored properties with doc comments, four entries in `AttentionConfig.default`, and four **defaulted** init parameters so no existing caller breaks:

```swift
    /// Percent at which roam ends itself and the machine sleeps deliberately.
    public var roamBatteryThreshold: Int
    /// The network you expect to be on while roaming. Best-effort: a warning, never a block.
    public var roamHotspotSSID: String?
    /// The "you seem to be at the desk — still need roam?" prompt.
    public var roamNudgeEnabled: Bool
    /// How long a dismissed nudge stays quiet.
    public var roamNudgeSnoozeMinutes: Int
```

Defaults: `10`, `nil`, `true`, `15`. Init parameters take those same defaults, so an older `config.json` with none of these keys still loads — the same rule every other field here follows.

- [ ] **Step 2: Write the failing test for the defaults**

Append to `Tests/AgentAttentionCoreTests/SoundAndSettingsTests.swift`:

```swift
    /// An existing config.json predates every roam key. It must still load, with roam
    /// off-by-default in the only sense that matters: sane thresholds, no invented SSID.
    @Test("Roam settings default safely and an older config still loads")
    func roamDefaults() throws {
        let config = AttentionConfig.default
        #expect(config.roamBatteryThreshold == 10)
        #expect(config.roamHotspotSSID == nil)
        #expect(config.roamNudgeEnabled)
        #expect(config.roamNudgeSnoozeMinutes == 15)

        let old = Data(#"{"soundEnabled": true}"#.utf8)
        let decoded = try JSONCoding.decoder.decode(AttentionConfig.self, from: old)
        #expect(decoded.roamBatteryThreshold == 10)
    }
```

> If `AttentionConfig` decodes via the synthesised `Codable` conformance, the older-file case requires a custom `init(from:)` that falls back to defaults for missing keys. Check how the existing optional fields (e.g. `chimeEnabled`) handle this and follow the same pattern — do not invent a second one.

- [ ] **Step 3: Run the test to verify it fails**

Run: `./Scripts/test.sh --filter "Roam settings default safely"`
Expected: FAIL — no member `roamBatteryThreshold`.

- [ ] **Step 4: Implement the config change, then re-run**

Run: `./Scripts/test.sh --filter "Roam settings default safely"`
Expected: PASS.

- [ ] **Step 5: Write `RoamService.swift`**

```swift
import Foundation
import AppKit
import AgentAttentionCore

/// Roam, from the app's side: enter, exit, and end itself before the battery does.
///
/// Everything decidable lives in `AgentAttentionCore` and is unit-tested — the lease, the
/// battery policy, the hotspot classification, the liveness rule. This class is the wiring.
final class RoamService {
    /// Called on the main thread whenever roam state changes, so the bubble and menus can
    /// redraw. Losing the lease is a change like any other, and must be visible.
    var onChange: (() -> Void)?

    private let paths: AppPaths
    private let assertion = SleepAssertion()
    private let lease = PowerLeaseClient()
    private var state: RoamState?
    private let log: (String) -> Void

    init(paths: AppPaths, log: @escaping (String) -> Void = { _ in }) {
        self.paths = paths
        self.log = log
        lease.onLost = { [weak self] in self?.leaseLost() }
    }

    var isActive: Bool { state != nil }
    var current: RoamState? { state }

    /// Enter roam, or fail without leaving anything half-applied.
    ///
    /// The lease is the gate. Idle sleep alone is not roam: if the block cannot be taken,
    /// the lid still sleeps the machine, and saying "roam is on" would be the one lie this
    /// feature must not tell. So a failed `acquire` releases the assertion and writes no
    /// state file.
    func enter(hotspot: RoamHotspot?, onBattery: Bool) -> Result<Void, PowerError> {
        guard state == nil else { return .success(()) }
        guard assertion.take() else { return .failure(.pmsetFailed) }
        switch lease.acquire() {
        case .failure(let error):
            assertion.release()
            log("roam refused: \(error.rawValue)")
            return .failure(error)
        case .success:
            let pid = ProcessInfo.processInfo.processIdentifier
            let started = ProcessProbe.snapshot(pid: pid)?.startedAt ?? 0
            let now = Date()
            state = RoamState(active: true, startedAt: now, ownerPID: pid,
                              ownerPIDStartedAt: started, leaseRenewedAt: now,
                              enteredOnBattery: onBattery, hotspot: hotspot)
            persist()
            log("roam on")
            onChange?()
            return .success(())
        }
    }

    func exit() {
        guard state != nil else { return }
        lease.release()
        assertion.release()
        state = nil
        try? FileManager.default.removeItem(at: paths.roamFile)
        log("roam off")
        onChange?()
    }

    /// The lease went away without us asking. The user finds out from the bubble, not from
    /// a flat battery.
    private func leaseLost() {
        guard state != nil else { return }
        assertion.release()
        state = nil
        try? FileManager.default.removeItem(at: paths.roamFile)
        log("roam ended: the power helper stopped holding the block")
        onChange?()
    }

    /// Called from AppDelegate's existing 15-second sweep. No new timer.
    func tick(reading: PowerReading, threshold: Int) {
        guard state != nil else { return }
        // The heartbeat has moved on; record it so a reader can tell a live session from a
        // file left behind by a crash.
        state?.leaseRenewedAt = Date()
        persist()

        switch RoamPolicy.guardAction(reading: reading, threshold: threshold,
                                      roamActive: true) {
        case .none:
            return
        case .exitAndSleep(let percent):
            // Order matters and is the spec's: tell the user, release and verify, drop the
            // assertion, then sleep. Sleeping first would strand the notification.
            notify(percent: percent)
            let released = lease.release()
            assertion.release()
            state = nil
            try? FileManager.default.removeItem(at: paths.roamFile)
            onChange?()
            guard released else {
                log("battery guard: could not confirm the sleep block was cleared — "
                    + "not sleeping. Repair with: sudo pmset -a disablesleep 0")
                return
            }
            if !SystemSleep.now() {
                log("battery guard: the system refused to sleep")
            }
        }
    }

    private func notify(percent: Int) {
        let alert = NSUserNotification()
        alert.title = "Agent Warden"
        alert.informativeText =
            "Battery at \(percent)% — ending roam and sleeping your Mac to save your work."
        NSUserNotificationCenter.default.deliver(alert)
    }

    private func persist() {
        guard let state else { return }
        guard let data = try? JSONCoding.encoder.encode(state) else { return }
        try? AtomicFile.write(data, to: paths.roamFile)
    }
}
```

> **Note for the executor:** `NSUserNotification` is deprecated. Check how the rest of this app posts notifications (`AlertDispatch`, `AppDelegate`) and use whatever it already uses rather than introducing a second mechanism.

- [ ] **Step 6: Wire it into `AppDelegate`**

Add `private let roam: RoamService`, construct it in `init` with `paths`, set `roam.onChange = { [weak self] in self?.render() }` after `super.init()`, and in `refresh()` beside the other services add:

```swift
        roam.tick(reading: PowerProbe.read(), threshold: config.roamBatteryThreshold)
```

`PowerProbe.read()` is a small new helper reading `pmset -g batt` / `pmset -g ps` into a `PowerReading`. Put it beside `RoamService` in the app target.

- [ ] **Step 7: Build and verify by hand**

```bash
swift build && ./Scripts/test.sh
```

Then, with the daemon installed from Phase 1, exercise from a scratch harness or the menu added in Phase 3:

| Check | Expected |
|---|---|
| Enter roam | `pmset -g \| grep SleepDisabled` shows `1`; `roam.json` exists |
| Close the lid for 2 minutes | The machine stays awake; sessions keep running |
| `sudo launchctl bootout system/dev.agentwarden.powerd` while roaming | Warden logs the lease loss, `roam.json` disappears |
| Exit roam | `SleepDisabled` back to `0`; `roam.json` gone |

- [ ] **Step 8: Review checkpoint**

**Phase 2 ships here.** Report the table with observed results. Stop. **Do not commit.**

---

# PHASE 3 — The UI

Ships when: roam toggles from both menus, the halo appears without disturbing the pending border, and the disc sits exactly where it sat before — including after a drag.

---

### Task 11: `haloInset` in the geometry, in both directions

The bubble window grows by 8pt permanently so a halo drawn outside the disc is not clipped. The stored corner offset must keep positioning **the disc**, not the window, or every existing bubble shifts 4pt inward on upgrade — and shifts again on every drag.

**Files:**
- Modify: `Sources/AgentAttentionCore/BubbleGeometry.swift`
- Test: `Tests/AgentAttentionCoreTests/BubbleGeometryTests.swift`

**Interfaces:**
- Consumes: existing `BubblePlacement`, `BubbleGeometry`.
- Produces: `BubbleGeometry.haloInset: CGFloat` (4), and `haloInset:` parameters on `frame(for:size:in:)`, `placement(for:in:)` and `panelFrame(...)`, each defaulting to `BubbleGeometry.haloInset` so existing callers compile unchanged.

- [ ] **Step 1: Read the current signatures**

Run: `sed -n '50,140p' Sources/AgentAttentionCore/BubbleGeometry.swift`

Note the exact parameter names and order of `frame(for:size:in:)`, `placement(for:in:)` and `panelFrame(...)`. The steps below add one parameter to each; keep everything else as it is.

- [ ] **Step 2: Write the failing test**

Append to `Tests/AgentAttentionCoreTests/BubbleGeometryTests.swift`:

```swift
    /// The window grows so the halo has somewhere to live. What must NOT move is the disc:
    /// the user put the bubble where they wanted it, and an upgrade that shifts it 4pt is
    /// an upgrade that moved their furniture.
    @Test("Growing the window for the halo leaves the disc exactly where it was")
    func discKeepsItsPlaceWhenTheWindowGrows() {
        let screen = CGRect(x: 0, y: 0, width: 1_600, height: 1_000)
        let placement = BubblePlacement(corner: .bottomRight, offsetX: 24, offsetY: 120)
        let discSize = CGSize(width: 56, height: 56)
        let inset = BubbleGeometry.haloInset

        let before = BubbleGeometry.frame(for: placement, size: discSize, in: screen,
                                          haloInset: 0)
        let after = BubbleGeometry.frame(
            for: placement,
            size: CGSize(width: discSize.width + inset * 2, height: discSize.height + inset * 2),
            in: screen, haloInset: inset)

        // The window is bigger, and the disc inside it lands on the old window's rect.
        #expect(after.insetBy(dx: inset, dy: inset) == before)
    }

    /// Dragging persists through `placement(for:)`. Without the same inset there, the
    /// bubble creeps 4pt further from the corner every single time it is dragged.
    @Test("A dragged bubble does not creep")
    func draggingDoesNotCreep() {
        let screen = CGRect(x: 0, y: 0, width: 1_600, height: 1_000)
        let inset = BubbleGeometry.haloInset
        let windowSize = CGSize(width: 64, height: 64)
        let placement = BubblePlacement(corner: .bottomRight, offsetX: 24, offsetY: 120)

        var frame = BubbleGeometry.frame(for: placement, size: windowSize, in: screen,
                                         haloInset: inset)
        for _ in 0..<5 {
            let round = BubbleGeometry.placement(for: frame, in: screen, haloInset: inset)
            frame = BubbleGeometry.frame(for: round, size: windowSize, in: screen,
                                         haloInset: inset)
        }
        #expect(abs(BubbleGeometry.placement(for: frame, in: screen, haloInset: inset).offsetX
                    - placement.offsetX) < 0.001)
        #expect(abs(BubbleGeometry.placement(for: frame, in: screen, haloInset: inset).offsetY
                    - placement.offsetY) < 0.001)
    }

    /// The panel sits next to the disc, not next to an invisible 4pt margin.
    @Test("The panel anchors to the disc, not the halo window")
    func panelAnchorsToTheDisc() {
        let screen = CGRect(x: 0, y: 0, width: 1_600, height: 1_000)
        let inset = BubbleGeometry.haloInset
        let window = CGRect(x: 1_500, y: 100, width: 64, height: 64)
        let panelSize = CGSize(width: 320, height: 400)

        let withHalo = BubbleGeometry.panelFrame(panelSize: panelSize, bubbleFrame: window,
                                                 in: screen, haloInset: inset)
        let withoutHalo = BubbleGeometry.panelFrame(
            panelSize: panelSize, bubbleFrame: window.insetBy(dx: inset, dy: inset),
            in: screen, haloInset: 0)
        #expect(withHalo == withoutHalo)
    }
```

> The `panelFrame` call above uses placeholder argument labels. Match them to the real signature you read in Step 1 before running.

- [ ] **Step 3: Run test to verify it fails**

Run: `./Scripts/test.sh --filter "Growing the window for the halo"`
Expected: FAIL — no `haloInset` parameter.

- [ ] **Step 4: Implement**

Add to `BubbleGeometry`:

```swift
    /// How far the disc sits inside its window, leaving room for the roam halo.
    ///
    /// The window is always this much bigger than the disc, whether roam is on or not.
    /// Growing it only while roaming would mean a window resize and a placement
    /// recomputation every time roam flipped — and the bubble visibly jumping. A constant
    /// margin costs 8pt of transparent window and nothing else.
    public static let haloInset: CGFloat = 4
```

Then, in each of the three functions, add `haloInset: CGFloat = BubbleGeometry.haloInset` as the final parameter and use it so that:

- `frame(for:size:in:haloInset:)` positions the **disc** at the stored offset: compute the frame as today using `size` reduced by `haloInset * 2`, then `insetBy(dx: -haloInset, dy: -haloInset)` to get the window rect.
- `placement(for:in:haloInset:)` reads the offset from the **disc** rect: `frame.insetBy(dx: haloInset, dy: haloInset)` before the existing distance calculations.
- `panelFrame(...haloInset:)` insets `bubbleFrame` by `haloInset` before its existing arithmetic.

Passing `haloInset: 0` must reproduce today's behaviour exactly — that is what the first test asserts.

- [ ] **Step 5: Run test to verify it passes**

Run: `./Scripts/test.sh --filter "Bubble"`
Expected: PASS, including every pre-existing `BubbleGeometryTests` case.

- [ ] **Step 6: Review checkpoint**

Run `./Scripts/test.sh`. Report and stop. **Do not commit.**

---

### Task 12: The inset disc and the halo

`BubbleView` currently paints the disc on **itself** — `applyAppearance` sets `layer?.backgroundColor`, `cornerRadius` and the pending border on the root view. Growing the window would therefore grow the disc, not create a margin. The disc has to become a child view first.

**Files:**
- Modify: `Sources/AgentAttentionApp/BubbleController.swift`

**Interfaces:**
- Consumes: `BubbleGeometry.haloInset` (Task 11), `RoamService.isActive` (Task 10).
- Produces: `BubbleView.update(pendingCount:unseenCount:expanded:roaming:)` — one added parameter.

- [ ] **Step 1: Introduce the child disc view**

In `BubbleView.build()`, create a `disc = NSView()` pinned to the view's bounds inset by `BubbleGeometry.haloInset` on all four sides, added **below** the glyph and badge. Move these three lines out of the root view and onto `disc.layer` in `applyAppearance`:

```swift
        disc.layer?.backgroundColor = (hovering || isExpanded ? lifted : base).cgColor
        disc.layer?.cornerRadius = disc.bounds.width / 2
        disc.layer?.borderWidth = 1
        disc.layer?.borderColor = (pendingCount > 0
            ? NSColor.systemOrange.withAlphaComponent(0.7)
            : NSColor.white.withAlphaComponent(0.18)).cgColor
```

The root view's own layer becomes transparent with no border and no corner radius. Re-pin the glyph, badge and total label to `disc` rather than to the root view so they stay centred on the disc.

- [ ] **Step 2: Add the halo**

Add a `halo = CAShapeLayer()` on the root view's layer, below the disc, and in `applyAppearance`:

```swift
        // Roam gets a channel of its own. The disc's border already means "sessions are
        // waiting", and overloading one surface with two meanings makes both harder to
        // read — so the halo lives in the margin outside the disc and the two compose:
        // roaming with three sessions waiting reads as both at once.
        let inset = BubbleGeometry.haloInset
        halo.frame = bounds
        halo.path = CGPath(ellipseIn: bounds.insetBy(dx: inset / 2, dy: inset / 2),
                           transform: nil)
        halo.fillColor = NSColor.clear.cgColor
        halo.lineWidth = inset
        halo.strokeColor = roaming
            ? NSColor.systemTeal.withAlphaComponent(0.85).cgColor
            : NSColor.clear.cgColor
```

- [ ] **Step 3: Take the margin out of the control**

`BubbleView.hitTest` currently returns the whole view for any hit inside it, which would make the transparent 4pt margin clickable and draggable. The halo is decoration, not a control:

```swift
    /// The glyph and the badge are decoration drawn on one control, so they must not
    /// hit-test as themselves. The **halo margin** is decoration too, and must not
    /// hit-test at all: a click a few points outside the disc should fall through to
    /// whatever is behind, exactly as it did before the window grew.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard disc.frame.contains(local) else { return nil }
        return super.hitTest(point) == nil ? nil : self
    }
```

- [ ] **Step 4: Thread the roam flag through**

Add `roaming: Bool` to `update(pendingCount:unseenCount:expanded:)`, store it, use it in `applyAppearance`, and extend the accessibility summary:

```swift
        setAccessibilityLabel(summary + (roaming ? " Roam is on." : ""))
```

Update the call site in `BubbleController` and `AppDelegate.render()` to pass `roam.isActive`.

- [ ] **Step 5: Update the window size**

Wherever the bubble window is sized from `config.bubbleSize`, add `BubbleGeometry.haloInset * 2` so the disc keeps the configured diameter.

- [ ] **Step 6: Build and check by eye**

```bash
./Scripts/build-app.sh
```

| Check | Expected |
|---|---|
| Roam off | Bubble looks exactly as before; no visible ring |
| Roam on | Teal ring outside the disc |
| Roam on **and** a session waiting | Teal ring **and** orange disc border, both legible |
| Click 3pt outside the disc | Falls through — does not open the panel or start a drag |
| Drag the bubble, quit, relaunch | Returns to the same place |

> `build-app.sh` installs and restarts the running app. Say so in your report.

- [ ] **Step 7: Review checkpoint**

Run `./Scripts/test.sh`. Report the table with observed results. Stop. **Do not commit.**

---

### Task 13: The menu item, in both menus

**Files:**
- Modify: `Sources/AgentAttentionApp/BubbleMenu.swift`
- Modify: `Sources/AgentAttentionApp/AppDelegate.swift`
- Test: `Tests/AgentAttentionCoreTests/` — see note below

**Interfaces:**
- Consumes: `RoamService`, `PowerError`.
- Produces: `BubbleMenu.roamItem(state:target:action:) -> NSMenuItem` and a `roam:` field on `BubbleMenu.Actions`.

- [ ] **Step 1: Write the item constructor**

```swift
    /// What the roam item should say and whether it can be used.
    ///
    /// A single constructor, for the same reason `quitItem` is one: the bubble menu and
    /// the menu bar menu must not drift, and roam is a machine-wide mode where drifting
    /// would mean two different ideas of whether the lid is safe to close.
    enum RoamMenuState: Equatable {
        case on
        case off
        /// The power helper is missing — roam cannot block lid-close sleep at all.
        case unavailable
        /// Something else already holds the machine's sleep block.
        case foreign
    }

    static func roamItem(state: RoamMenuState, target: AnyObject, action: Selector) -> NSMenuItem {
        let title: String
        switch state {
        case .on: title = "Turn roam off"
        case .off: title = "Turn roam on"
        case .unavailable: title = "Roam needs the power helper — run install.sh"
        case .foreign: title = "Roam unavailable — another tool holds sleep"
        }
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = target
        // Disabled states carry their reason in the title rather than being silently grey:
        // "nothing happens when I click it" is the worst possible answer.
        item.isEnabled = (state == .on || state == .off)
        item.setAccessibilityLabel(title)
        return item
    }
```

Add `var roam: NSMenuItem?` to `BubbleMenu.Actions`, and insert it in `build(...)` directly above the placement item.

- [ ] **Step 2: Add the test**

`BubbleMenu` lives in the app target, which tests cannot import. Move `RoamMenuState` and a pure `roamTitle(for:) -> String` into `AgentAttentionCore` (a new `RoamMenuText.swift`), have `roamItem` call it, and test the text there:

```swift
@Suite("What the roam menu item says")
struct RoamMenuTextTests {
    @Test("Each state says what it is, and a disabled one says why")
    func titles() {
        #expect(RoamMenuText.title(for: .on) == "Turn roam off")
        #expect(RoamMenuText.title(for: .off) == "Turn roam on")
        #expect(RoamMenuText.title(for: .unavailable).contains("install.sh"))
        #expect(RoamMenuText.title(for: .foreign).contains("another tool"))
    }

    @Test("Only the two real states are actionable")
    func enablement() {
        #expect(RoamMenuText.isActionable(.on))
        #expect(RoamMenuText.isActionable(.off))
        #expect(!RoamMenuText.isActionable(.unavailable))
        #expect(!RoamMenuText.isActionable(.foreign))
    }
}
```

- [ ] **Step 3: Run the test**

Run: `./Scripts/test.sh --filter "What the roam menu item says"`
Expected: FAIL first, then PASS once `RoamMenuText` exists.

- [ ] **Step 4: Wire the action in `AppDelegate`**

```swift
    @objc private func toggleRoam() {
        if roam.isActive {
            roam.exit()
            return
        }
        let hotspot = RoamHotspot(kind: RoamNetwork.classify(gateway: PowerProbe.gateway()).rawValue,
                                  ssid: PowerProbe.ssid())
        switch roam.enter(hotspot: hotspot, onBattery: !PowerProbe.read().onAC) {
        case .success:
            // A warning, never a block: the user may know exactly what they are doing.
            if let saved = config.roamHotspotSSID, let now = PowerProbe.ssid(), saved != now {
                panel.flash("Roam is on — but you're on “\(now)”, not “\(saved)”.", seconds: 12)
            }
        case .failure(let error):
            panel.flash("Roam could not start: \(error.rawValue)", seconds: 12)
        }
        render()
    }
```

Pass the item into both menus via `BubbleMenu.Actions.roam`, and add the same item to the menu bar menu construction.

- [ ] **Step 5: Verify by hand**

| Check | Expected |
|---|---|
| Toggle from the bubble's right-click menu | Roam on, halo appears, `SleepDisabled` is `1` |
| Toggle from the menu bar menu | Same result, same wording |
| With the daemon uninstalled | Both items disabled, saying "run install.sh" |
| With `sudo pmset -a disablesleep 1` set externally | Both items disabled, saying another tool holds sleep |

- [ ] **Step 6: Review checkpoint**

**Phase 3 ships here.** Report the table. Stop. **Do not commit.**

---

# PHASE 4 — The footer

Ships when: `🎒 roam on` appears in a live Claude Code session footer, the redmy heavy-lock segment survives, and killing Warden makes the indicator stop.

---

### Task 14: The indicator and the `aa-roam` binary

**Files:**
- Create: `Sources/AgentAttentionCore/RoamIndicator.swift`
- Create: `Sources/AARoam/main.swift`
- Modify: `Package.swift`, `install.sh`
- Test: `Tests/AgentAttentionCoreTests/RoamIndicatorTests.swift`

**Interfaces:**
- Consumes: `RoamState` (Task 6).
- Produces: `RoamIndicator.text(state:now:probe:) -> String` and an `aa-roam` executable.

- [ ] **Step 1: Write the failing test**

```swift
import Foundation
import Testing
@testable import AgentAttentionCore

@Suite("The roam footer indicator")
struct RoamIndicatorTests {

    private let t0 = Date(timeIntervalSince1970: 4_000_000)

    private func live() -> RoamState {
        RoamState(active: true, startedAt: t0, ownerPID: 4711, ownerPIDStartedAt: 500,
                  leaseRenewedAt: t0, enteredOnBattery: false)
    }

    @Test("An active session prints the badge")
    func printsWhenOn() {
        #expect(RoamIndicator.text(state: live(), now: t0, probe: { _ in 500 }) == "🎒 roam on")
    }

    @Test("No state at all prints nothing")
    func silentWhenAbsent() {
        #expect(RoamIndicator.text(state: nil, now: t0, probe: { _ in 500 }) == "")
    }

    /// The bug this closes: SIGKILL Warden and the file stays behind. Without validation
    /// every session footer on the machine would keep claiming the lid was safe to close.
    @Test("A file left behind by a dead app prints nothing")
    func silentWhenOwnerIsGone() {
        #expect(RoamIndicator.text(state: live(), now: t0, probe: { _ in nil }) == "")
    }

    @Test("A stale lease prints nothing")
    func silentWhenLeaseIsStale() {
        #expect(RoamIndicator.text(state: live(), now: t0.addingTimeInterval(120),
                                   probe: { _ in 500 }) == "")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `./Scripts/test.sh --filter "The roam footer indicator"`
Expected: FAIL — `cannot find 'RoamIndicator' in scope`.

- [ ] **Step 3: Write minimal implementation**

```swift
import Foundation

/// The one string a Claude Code session footer shows for roam.
///
/// Deliberately trivial and deliberately validated. It runs on every status-line refresh,
/// so it reads one file and makes no IPC call — but it must never print from a file that
/// a killed app left behind, because "🎒 roam on" is a claim that the lid is safe to close.
public enum RoamIndicator {
    public static let badge = "🎒 roam on"

    public static func text(state: RoamState?, now: Date = Date(),
                            probe: (Int32) -> Double?) -> String {
        guard let state, state.isLive(now: now, probe: probe) else { return "" }
        return badge
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `./Scripts/test.sh --filter "The roam footer indicator"`
Expected: PASS, 4 tests.

- [ ] **Step 5: Write `Sources/AARoam/main.swift`**

```swift
import Foundation
import AgentAttentionCore

// A short-lived process cannot own roam: the idle assertion and the daemon lease are held
// by a live process, so a CLI that entered roam would drop both the instant it exited.
// `on` and `off` therefore ask the running app to do it, exactly as `aa-status` asks it
// for the queue. Only `indicator` and `status` work standalone, because both only read.

let paths = AppPaths.resolved()
let arguments = Array(CommandLine.arguments.dropFirst())

func loadState() -> RoamState? {
    guard let data = try? Data(contentsOf: paths.roamFile) else { return nil }
    return try? JSONCoding.decoder.decode(RoamState.self, from: data)
}

func liveness(_ pid: Int32) -> Double? { ProcessProbe.snapshot(pid: pid)?.startedAt }

switch arguments.first {
case "indicator":
    FileHandle.standardOutput.write(Data(
        RoamIndicator.text(state: loadState(), probe: liveness).utf8))

case "status":
    if let state = loadState(), state.isLive(probe: liveness) {
        let minutes = Int(Date().timeIntervalSince(state.startedAt) / 60)
        print("roam on — \(minutes) min, owner pid \(state.ownerPID)")
    } else {
        print("roam off")
    }

case "on", "off":
    // Routed through the running app over the existing bridge socket. If Warden is not
    // running this fails and says so — it never pretends to have done something.
    let request = arguments[0] == "on" ? "roam-on" : "roam-off"
    switch BridgeSocketClient.send(BridgeRequest(command: request), to: paths.bridgeSocket.path) {
    case .success(let reply): print(reply.summary)
    case .failure:
        FileHandle.standardError.write(Data(
            "Agent Warden is not running — start it, then try again.\n".utf8))
        exit(1)
    }

default:
    print("""
    aa-roam — Agent Warden roam mode

      aa-roam indicator   Print "🎒 roam on" when roam is active (for the status line)
      aa-roam status      Human-readable state
      aa-roam on          Ask the running app to enter roam
      aa-roam off         Ask the running app to leave roam
    """)
}
```

> **Note for the executor:** the exact `BridgeRequest` / `BridgeResponse` shape and the bridge socket path are in `Sources/AgentAttentionCore/BridgeProtocol.swift` and `Paths.swift`. Read them and match; the sketch above uses placeholder names. Add the two commands to the bridge's existing verb handling in the app.

- [ ] **Step 6: Add the target and the symlink**

In `Package.swift`, add the product `.executable(name: "aa-roam", targets: ["AARoam"])` and a matching `executableTarget` depending on `AgentAttentionCore` with `.swiftLanguageMode(.v5)`.

In `install.sh`, add `aa-roam` to `LINK_NAMES`.

- [ ] **Step 7: Verify**

```bash
swift build && ./Scripts/build-app.sh
aa-roam status
aa-roam indicator; echo
```

Expected: `roam off` and an empty indicator when roam is off; `roam on — N min` and `🎒 roam on` when it is on.

- [ ] **Step 8: Review checkpoint**

Run `./Scripts/test.sh`. Report and stop. **Do not commit.**

---

### Task 15: The statusline migration

The most delicate step, and the reason it is last. This machine's `statusLine.command` points at `~/.claude/bin/roam-wrapped-statusline.sh` — a file the roam plugin generated and owns, which chains the user's own `wunda-statusline.sh` **and** carries a hand-added redmy heavy-run-lock segment with a comment warning it is lost on regeneration. Uninstalling the plugin deletes that file and takes both with it.

**Files:**
- Create: `Scripts/manage-statusline.py`
- Modify: `install.sh`, `uninstall.sh`

**Interfaces:**
- Consumes: the `aa-roam` binary (Task 14).
- Produces: `~/.claude/bin/agent-warden-statusline.sh` and a `statusLine` entry pointing at it.

- [ ] **Step 1: Write `Scripts/manage-statusline.py`**

Model it on the existing `Scripts/manage-hooks.py` — same argument style, same backup discipline, same manifest recording. It must:

1. `check` — print `absent`, `ours`, `roam-plugin`, or `other`.
2. `install` — build `~/.claude/bin/agent-warden-statusline.sh` and repoint `statusLine.command` at it. When the current command is a roam-plugin wrapper, **carry over every line of it**: the `ORIG_OUT=` chain, any hand-added segments, and the final `printf` — replacing only the roam indicator invocation with `aa-roam indicator`. Never regenerate from a template.
3. `--dry-run` — print the resulting wrapper and change nothing. **Default to this**, and require an explicit confirmation before writing.
4. Back up `~/.claude/settings.json` with a timestamp first, and record the change in `install-manifest.json`.
5. `uninstall` — restore the previous `statusLine.command` from the manifest and delete Warden's wrapper.

The parsing rule for carrying segments over: keep every line, and replace only lines matching `roam-cli["'\s]+indicator` or `roam-indicator\.sh` with the `aa-roam indicator` equivalent. Anything not matched is copied verbatim — that is what preserves the heavy-lock block.

- [ ] **Step 2: Test the migration on a copy, not on the live file**

```bash
mkdir -p /tmp/statusline-test
cp ~/.claude/settings.json /tmp/statusline-test/settings.json
cp ~/.claude/bin/roam-wrapped-statusline.sh /tmp/statusline-test/
/usr/bin/python3 Scripts/manage-statusline.py install \
  --settings /tmp/statusline-test/settings.json --dry-run
```

Expected: the printed wrapper contains, in order — the `wunda-statusline.sh` call, an `aa-roam indicator` call in place of the `roam-cli indicator` call, and the redmy heavy-lock block **intact, including its comment**.

**Diff the two wrappers and confirm the only changed lines are the indicator ones.**

- [ ] **Step 3: Wire into `install.sh` and `uninstall.sh`**

```bash
echo "== Claude Code status line =="
/usr/bin/python3 "$ROOT/Scripts/manage-statusline.py" install --settings "$SETTINGS" $DRY_RUN
```

and the matching `uninstall` call in `uninstall.sh`.

- [ ] **Step 4: Apply for real and verify in a live session**

Run the installer without `--dry-run`, then in a **new** Claude Code session check the footer.

| Check | Expected |
|---|---|
| Roam on | Footer shows `🎒 roam on` |
| Roam off | Badge gone, everything else unchanged |
| The redmy heavy-lock segment | Still appears when the lock is held |
| `wunda-statusline.sh` output | Unchanged — directory, branch, model, ctx% all present |
| Kill Warden with `SIGKILL` while roaming | Badge disappears within the lease window |

- [ ] **Step 5: Review checkpoint**

**Phase 4 ships here — the feature is complete.** Report the table with observed results, and state plainly that `~/.claude/settings.json` was modified and where the backup is. Stop. **Do not commit.**

---

## After all four phases

- [ ] Update `README.md`: roam mode, the power helper, the halo, `aa-roam`, and the emergency repair `sudo pmset -a disablesleep 0`.
- [ ] Update `BACKLOG.md`: note that roam is native and the `claude-code-roam` dependency is gone.
- [ ] Tell the user the plugin can now be retired — `/roam:uninstall`, then remove it — and that the statusline migration in Task 15 must already have happened, because uninstalling deletes the plugin's wrapper file.

## Plan self-review

Checked against the spec on 2026-09-09:

- **Spec coverage.** Every spec section maps to a task: daemon install and ownership → Task 5; socket activation → Tasks 4–5; protocol → Task 2; exclusive heartbeat lease → Tasks 3, 4, 9; `SleepDisabled` as global state → Tasks 1, 3, 4; cleanup and recovery → Tasks 4, 5; peer check → Tasks 4, 9; `BridgeSocket` primitives-only → Tasks 4, 9; logging → Task 4; `RoamService` → Task 10; idle-only assertion → Task 9; `IOPMSleepSystem` → Task 9; battery guard ordering → Tasks 7, 10; `RoamNetwork` → Task 8; halo → Tasks 11–12; menus → Task 13; `aa-roam` → Task 14; statusline migration → Task 15; `roam.json` and liveness → Task 6; config → Task 10; known limits → carried as comments in Tasks 1, 3, 8, 9.
- **Placeholder scan.** Three places name a signature the executor must read from the repo first rather than trust from here — `panelFrame`'s labels (Task 11), the `BridgeRequest` shape (Task 14), and the notification mechanism (Task 10). Each is called out inline with the file to read. These are deliberate: inventing those signatures would be worse than sending the executor to the source.
- **Type consistency.** `PowerError` cases used in Tasks 3, 4, 9 and 13 all come from the single definition in Task 2. `SleepDisabled` is `.on`/`.off`/`.unknown` throughout. `PowerLease.Effect` is `.none`/`.setBlock`/`.clearBlock` in Tasks 3 and 4. `RoamState.isLive(now:leaseWindow:probe:)` has the same signature in Tasks 6 and 14. `BubbleGeometry.haloInset` is one constant used in Tasks 11 and 12.
