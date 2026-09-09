import Foundation
import IOKit
import IOKit.pwr_mgt

/// Put the machine to sleep deliberately.
///
/// This is the last act of the battery guard: roam ends itself while there is still charge,
/// and spends what is left on a clean sleep rather than a hard stop.
///
/// **It needs no privilege escalation, and no AppleScript.** An earlier revision of the
/// design claimed `IOPMSleepSystem` requires root and substituted
/// `tell application "System Events" to sleep`. That was wrong on both counts. The SDK
/// header (`IOKit.framework/Headers/pwr_mgt/IOPMLib.h`) is explicit:
///
/// > "For security purposes, caller must be root or the console user."
///
/// Agent Warden runs as the console user, so it may call this directly. The AppleScript
/// route, by contrast, is gated by Automation/TCC, which can be denied, revoked, or waiting
/// on a consent dialog that nobody can answer with the lid shut — precisely the moment this
/// is needed, and precisely the moment a silent refusal costs the battery it was called to
/// save.
///
/// **The block is released first, and that ordering is not decoration.** The caller gives
/// the power lease back, confirms the daemon acknowledged it, and only then calls here —
/// which is the whole reason `PowerLeaseClient.release()` returns a `Bool` at all. Asking
/// for sleep while the machine-wide block may still stand risks the worst outcome this
/// feature has: a user told their Mac was sleeping to save their work, over a machine that
/// stayed awake on a dying battery.
enum SystemSleep {
    /// Ask the root power domain to sleep, and report whether it agreed.
    ///
    /// Deliberately **not** `@discardableResult`. The return code is checked rather than
    /// assumed because it can genuinely be false: under fast user switching this app may no
    /// longer be the console user, and the header's security rule then refuses the request.
    /// A caller that discards this answer has assumed the machine slept, which is the
    /// mistake the type comment above describes.
    ///
    /// Both failure modes — no handle, or a refused request — are folded into `false` on
    /// purpose. There is exactly one useful action either way, which is to say so and stop,
    /// and an `IOReturn` handed to a caller that cannot act on it is decoration.
    static func now() -> Bool {
        // MACH_PORT_NULL is what the header asks for here ("Just pass in MACH_PORT_NULL for
        // master device port"); it means the default, not a missing argument.
        let port = IOPMFindPowerManagement(mach_port_t(MACH_PORT_NULL))
        // A zero handle is the failure return, and passing it on would be a call into the
        // kernel with a port that was never opened.
        guard port != 0 else { return false }
        // The header requires this handle to be released with `IOServiceClose`. `defer`
        // rather than a call placed after the sleep request, so that a future early return
        // added between here and the end of the function cannot leak a mach port.
        defer { IOServiceClose(port) }
        return IOPMSleepSystem(port) == kIOReturnSuccess
    }
}
