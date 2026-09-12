import AppKit
import AgentAttentionCore

/// The app's two jobs for the bridge: keep a host running while the app runs, and answer the one
/// request only the app can — focus a tab the user linked.
///
/// The host is `aa-bridge serve` from this bundle, a child process rather than code in this one,
/// so a host that crashes costs its own sessions and not the queue, the bubble or the alerts.
final class BridgeService {
    private let paths: AppPaths
    private var supervisor: BridgeSupervisor?
    private var control: BridgeSocketServer?
    var log: ((String) -> Void)?
    /// Focus a linked tab on the main thread and report the outcome. Supplied by the delegate,
    /// which owns the queue and the links.
    var focusLinkedTab: ((String, @escaping (BridgeResponse) -> Void) -> Void)?

    init(paths: AppPaths) {
        self.paths = paths
    }

    func start() {
        startControlEndpoint()
        let settings = BridgeSettings.load(from: paths.bridgeSettingsFile)
        guard settings.enabled else {
            log?("bridge host not started: disabled in \(paths.bridgeSettingsFile.lastPathComponent)")
            return
        }
        guard let executable = Bundle.main.executableURL?.deletingLastPathComponent()
            .appendingPathComponent("aa-bridge").path,
              FileManager.default.isExecutableFile(atPath: executable) else {
            log?("bridge host not started: no aa-bridge beside this app")
            return
        }
        let socket = paths.bridgeSocket.path
        let supervisor = BridgeSupervisor(
            launcher: BridgeHostProcessLauncher(
                executable: executable,
                // No --approve: the host reads the user's own bridge.json on every request, so
                // nothing here decides — or can widen — where sessions may run.
                arguments: ["serve", "--socket", socket, "--roots-file", paths.bridgeSettingsFile.path],
                logFile: paths.root.appendingPathComponent("bridge-host.log")),
            healthCheck: {
                (try? BridgeSocketClient.send(.status(sessionID: nil), to: socket, timeout: 5))?.ok == true
            })
        let log = self.log
        supervisor.log = { message in DispatchQueue.main.async { log?(message) } }
        supervisor.start()
        self.supervisor = supervisor
    }

    /// Asks the host to go and waits, bounded, for it to have gone — so quitting the app does not
    /// leave a host, or the sessions it owns, behind.
    func stop() {
        if let supervisor, !supervisor.stop() {
            log?("bridge host had to be forced to stop")
        }
        control?.stop()
    }

    var hostState: BridgeSupervisor.State? { supervisor?.state }

    private func startControlEndpoint() {
        let server = BridgeSocketServer(path: paths.appControlSocket.path) { [weak self] request in
            guard case .focus(let sessionID) = request else {
                return BridgeResponse(ok: false, error: BridgeError(
                    code: .unknownRequest, message: "The app answers focus requests only."))
            }
            return self?.focus(sessionID) ?? BridgeResponse(ok: false, error: BridgeError(
                code: .clientUnavailable, message: "The app is shutting down."))
        }
        do {
            try server.start()
            control = server
        } catch {
            log?("could not open the focus endpoint: \(error.localizedDescription)")
        }
    }

    /// Called on a socket worker; the focus itself happens on the main thread, and this waits for
    /// its verified outcome — bounded, and reported as unconfirmed rather than guessed at.
    private func focus(_ sessionID: String) -> BridgeResponse {
        let done = DispatchSemaphore(value: 0)
        let box = ResponseBox()
        DispatchQueue.main.async { [weak self] in
            guard let focusLinkedTab = self?.focusLinkedTab else {
                box.value = BridgeResponse(ok: false, error: BridgeError(
                    code: .clientUnavailable, message: "The app is not ready to focus anything."))
                done.signal()
                return
            }
            focusLinkedTab(sessionID) { response in
                box.value = response
                done.signal()
            }
        }
        guard done.wait(timeout: .now() + 15) == .success, let response = box.value else {
            return BridgeResponse(ok: false, error: BridgeError(
                code: .clientUnavailable,
                message: "The focus did not finish in time; whether the tab changed is unknown."))
        }
        return response
    }

    private final class ResponseBox: @unchecked Sendable {
        var value: BridgeResponse?
    }
}
