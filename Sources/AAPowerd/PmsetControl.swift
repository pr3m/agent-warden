import Foundation
import AgentAttentionCore

/// The only privileged thing this daemon does: write and read the machine-global
/// `SleepDisabled` setting.
///
/// **Why this is two fixed argument vectors and not a command string.** The daemon runs as
/// root and takes its orders off a socket. `acquire` and `release` map to `disablesleep 1`
/// and `disablesleep 0` and to nothing else — the protocol carries no arguments, so there
/// is no value from the wire to interpolate and no shell to interpolate it into. `Process`
/// with an `executableURL` execs directly; it never goes through `/bin/sh`.
///
/// **Why the absolute path.** `pmset` is addressed as `/usr/bin/pmset`. A relative name
/// would be resolved against whatever `PATH` this process inherited, which is a way to
/// make a root daemon exec somebody else's binary.
///
/// **Why every write is read back.** `pmset -a disablesleep` is undocumented and
/// unsupported: it can exit 0 without changing anything. An unverified write is reported as
/// a failure, never as a success, because the alternative is telling the user their Mac
/// will stay awake with the lid shut when it will not.
enum PmsetControl {
    /// Fixed, absolute, and never assembled from anything the socket supplied.
    static let executable = "/usr/bin/pmset"

    /// Set or clear the block, then **verify by reading it back**.
    ///
    /// Returns `nil` on a verified change, or the `PowerError` that describes what went
    /// wrong. `.unverified` means the write reported success and the read-back disagreed —
    /// which is treated exactly like an outright failure, because from the caller's point
    /// of view it is one.
    static func write(_ wanted: SleepDisabled) -> PowerError? {
        // `.unknown` is not a state anything can be written to. Refusing here keeps the
        // caller from ever turning "we could not read it" into "go and set it to that".
        guard wanted == .on || wanted == .off else { return .unverified }
        let value = wanted == .on ? "1" : "0"
        guard run([executable, "-a", "disablesleep", value]) == 0 else { return .pmsetFailed }
        return read() == wanted ? nil : .unverified
    }

    /// The current machine-wide setting as `pmset` reports it. Anything we cannot run or
    /// cannot parse is `.unknown` and never `.off`.
    static func read() -> SleepDisabled {
        guard let output = capture([executable, "-g"]) else { return .unknown }
        return SleepDisabled.parse(output)
    }

    private static func run(_ argv: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: argv[0])
        process.arguments = Array(argv.dropFirst())
        // A root daemon's child must not inherit this process's stdio: whatever launchd
        // handed us is not a place to spray output, and a full pipe would hang the wait.
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
        // Drain before waiting, never after: a child that fills the pipe buffer blocks on
        // write, and a parent already blocked in `waitUntilExit` would never drain it.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
