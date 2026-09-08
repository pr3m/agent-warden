import AppKit
import AgentAttentionCore

/// Opens the selected document for editing, or explains why it will not.
///
/// A protocol so the UI check can exercise every button without a single application launching on
/// anyone's machine.
protocol ContractOpening: AnyObject {
    /// Asks the system to open it, and reports what actually happened — `nil` for opened, a
    /// sentence otherwise.
    ///
    /// A completion handler rather than a return value, because launching an application is
    /// asynchronous: returning "opened" the instant the request was posted meant the window said
    /// so even when the launch then failed.
    func openForEditing(_ path: String, completion: @escaping (String?) -> Void)
    /// Show it in the Finder without opening it. Always available, because looking at where a file
    /// lives cannot run anything.
    func reveal(_ path: String)
}

/// The real one: a **text editor**, chosen for the plain-text type, never the file's own
/// association.
///
/// This is the difference between "open my agreement" and "run whatever this extension is wired
/// to". The reader has already refused executables, bundles, scripts and active documents; this
/// then declines to consult the association table at all, and hands the file to a text editor by
/// name. If no text editor can be found, nothing is launched and the window says so — revealing it
/// in the Finder is offered instead.
final class SystemContractOpener: ContractOpening {
    func openForEditing(_ path: String, completion: @escaping (String?) -> Void) {
        guard let editor = SystemContractOpener.textEditor() else {
            completion("No plain-text editor could be found, so nothing was opened. "
                       + "Use Reveal in Finder and open it yourself.")
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open([URL(fileURLWithPath: path)], withApplicationAt: editor,
                                configuration: configuration) { application, error in
            // The system answers on its own queue; the window is main-thread only.
            DispatchQueue.main.async {
                if let error {
                    completion("It could not be opened: \(error.localizedDescription)")
                } else if application == nil {
                    completion("The editor did not report that it opened the document.")
                } else {
                    completion(nil)
                }
            }
        }
    }

    func reveal(_ path: String) {
        NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "")
    }

    /// TextEdit if it is where it always is; otherwise whatever handles *plain text* — which is a
    /// question about a content type, not about this file's extension.
    static func textEditor() -> URL? {
        let textEdit = URL(fileURLWithPath: "/System/Applications/TextEdit.app")
        if FileManager.default.fileExists(atPath: textEdit.path) { return textEdit }
        return NSWorkspace.shared.urlForApplication(toOpen: .plainText)
    }
}

/// Choose, inspect, clear — and, only when asked, open.
///
/// The window is a view onto one line of configuration and one file on disk. It re-reads both every
/// time it is shown or acted on, so what it says is what is true now rather than what was true when
/// it opened. Escape and the close button are always safe: nothing is written except by the button
/// that says it writes, and a failure to write is shown rather than swallowed.
final class ContractWindow: NSObject, NSWindowDelegate {
    /// Store this selection. `nil` clears it. Returns whether it actually reached disk.
    var onSelect: ((String?) -> Bool)?
    /// Injected in the UI check so no chooser is ever presented. `nil` means use the real panel.
    var chooser: (() -> String?)?
    var opener: ContractOpening = SystemContractOpener()

    private var window: NSWindow?
    private var reading = ContractReading(availability: .noSelection, readAt: Date(),
                                          note: "No orchestration contract is selected.")
    /// Bumped by anything that makes an in-flight open irrelevant, so a late answer about a
    /// document that is no longer selected cannot overwrite what the window is saying now.
    private var openGeneration = 0

    private let headline = NSTextField(labelWithString: "")
    private let pathLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let pathField = NSTextField(string: "")
    private var openButton: ClosureButton?
    private var revealButton: ClosureButton?
    private var clearButton: ClosureButton?

    // MARK: - Presenting

    func show(selection: String?) {
        build()
        refresh(selection: selection)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func close() {
        openGeneration += 1        // anything still in flight is no longer this window's business
        window?.orderOut(nil)
    }

    /// The titlebar close is a close like any other.
    ///
    /// Clearing the label was not enough: an open still in flight would come back, find the same
    /// selection when the window was reopened, and write "Opened in a text editor" over whatever
    /// the window was saying then. Closing invalidates it, exactly as `close()` does.
    func windowWillClose(_ notification: Notification) {
        openGeneration += 1
        statusLabel.stringValue = ""
    }

    /// Re-read, and say exactly what is there.
    private func refresh(selection: String?, status: String? = nil) {
        if selection != reading.selectedPath { openGeneration += 1 }
        reading = OrchestrationContract.read(selection: selection, includeContent: false)
        headline.stringValue = ContractWindow.headline(for: reading.availability)
        pathLabel.stringValue = reading.selectedPath ?? "Nothing selected"
        detailLabel.stringValue = ContractWindow.detail(for: reading)
        pathField.stringValue = reading.selectedPath ?? ""
        if let status { statusLabel.stringValue = status }

        // Open is offered only for a document that has already been read successfully. Everything
        // else gets Reveal, which cannot start anything.
        let openable: Bool
        if case .allowed = OrchestrationContract.openDecision(for: reading) { openable = true }
        else { openable = false }
        openButton?.isEnabled = openable
        revealButton?.isEnabled = reading.resolvedPath != nil
        clearButton?.isEnabled = reading.selectedPath != nil
    }

    static func headline(for availability: ContractAvailability) -> String {
        switch availability {
        case .noSelection: return "No contract selected"
        case .available: return "Contract selected and readable"
        case .missing: return "Selected — but the file is missing"
        case .notRegularFile: return "Selected — but that is not a document"
        case .unsupportedType: return "Selected — but that type is not supported"
        case .tooLarge: return "Selected — but too large to read"
        case .notText: return "Selected — but not UTF-8 text"
        case .unreadable: return "Selected — but it could not be read"
        case .changedWhileReading: return "It changed while being read"
        case .configUnreadable: return "The settings file could not be read"
        }
    }

    static func detail(for reading: ContractReading) -> String {
        var parts: [String] = [reading.note]
        if let size = reading.sizeBytes { parts.append("\(size) bytes") }
        if let modified = reading.modifiedAt {
            parts.append("modified " + DateFormatter.localizedString(from: modified,
                                                                    dateStyle: .short,
                                                                    timeStyle: .short))
        }
        if let revision = reading.revision { parts.append("revision " + revision.prefix(12)) }
        return parts.joined(separator: " · ")
    }

    // MARK: - Actions

    /// The system chooser, or the injected stand-in. Cancelling changes nothing at all.
    func chooseFile() {
        let picked: String?
        if let chooser {
            picked = chooser()
        } else {
            let panel = NSOpenPanel()
            panel.canChooseFiles = true
            panel.canChooseDirectories = false
            panel.allowsMultipleSelection = false
            panel.message = "Choose the document that holds your working agreement."
            panel.prompt = "Select"
            panel.allowedContentTypes = [.plainText, .text]
            picked = panel.runModal() == .OK ? panel.url?.path : nil
        }
        guard let picked else {
            statusLabel.stringValue = "Nothing was changed."
            return
        }
        store(picked)
    }

    /// A path typed or pasted in. The same rules apply — the chooser's filter was never the check.
    func useTypedPath() {
        let typed = pathField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty else {
            statusLabel.stringValue = "Type a path, or use Choose file."
            return
        }
        store(typed)
    }

    func clearSelection() {
        guard onSelect?(nil) == true else {
            refresh(selection: reading.selectedPath,
                    status: "The selection could not be cleared, so it is unchanged on disk.")
            return
        }
        refresh(selection: nil, status: "Cleared. Nothing was deleted — only the selection is gone.")
    }

    /// Selecting is not opening: the document is read to report on it, and left closed.
    private func store(_ path: String) {
        guard onSelect?(path) == true else {
            refresh(selection: reading.selectedPath,
                    status: "That selection could not be saved. Nothing was changed on disk.")
            return
        }
        refresh(selection: path,
                status: "Saved. The document itself was not opened or changed.")
    }

    func openForEditing() {
        // Re-read first. The state shown a minute ago is not permission to open something now.
        refresh(selection: reading.selectedPath)
        switch OrchestrationContract.openDecision(for: reading) {
        case .refused(let why):
            statusLabel.stringValue = why
        case .allowed(let path):
            // Nothing is claimed yet. "Opening" is what is true at this instant; whether it opened
            // is something only the system can say, and it says so later.
            openGeneration += 1
            let generation = openGeneration
            let opening = reading.selectedPath
            statusLabel.stringValue = "Opening \((path as NSString).lastPathComponent)…"
            opener.openForEditing(path) { [weak self] problem in
                guard let self, generation == self.openGeneration,
                      self.reading.selectedPath == opening else {
                    return          // a later action, or a different document: this answer is stale
                }
                self.statusLabel.stringValue = problem
                    ?? "Opened in a text editor. Agent Warden did not change it."
            }
        }
    }

    func revealInFinder() {
        guard let path = reading.resolvedPath else { return }
        opener.reveal(path)
        statusLabel.stringValue = "Shown in the Finder. Nothing was opened."
    }

    // MARK: - The window

    private func build() {
        guard window == nil else { return }
        let window = EscapeClosableWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 380),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        // Escape is a close, and a close is safe: nothing here is pending, because nothing is
        // written except by a button that says it writes.
        window.onCancel = { [weak self] in self?.close() }
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.title = "Orchestration contract"
        window.center()
        ClickCursor.prepare(window)

        headline.font = .systemFont(ofSize: 14, weight: .semibold)
        pathLabel.font = .systemFont(ofSize: 12)
        pathLabel.textColor = .secondaryLabelColor
        pathLabel.isSelectable = true
        pathLabel.lineBreakMode = .byTruncatingMiddle
        detailLabel.font = .systemFont(ofSize: 11)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = .byWordWrapping
        detailLabel.maximumNumberOfLines = 4
        detailLabel.preferredMaxLayoutWidth = 520
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byWordWrapping
        statusLabel.maximumNumberOfLines = 3
        statusLabel.preferredMaxLayoutWidth = 520

        let explanation = NSTextField(wrappingLabelWithString:
            "One document you keep wherever you like: the working agreement Agent Warden and its "
            + "consumers read. Choosing it stores a path and nothing else — the file is never "
            + "changed, never run, and never opened unless you ask. It is your policy, inside "
            + "whatever the tools already permit; it does not grant anyone new permission, and it "
            + "does not make an assistant load anything by itself.")
        explanation.font = .systemFont(ofSize: 11)
        explanation.textColor = .secondaryLabelColor
        explanation.preferredMaxLayoutWidth = 520

        pathField.placeholderString = "…or paste a path to a Markdown or text file"
        pathField.font = .systemFont(ofSize: 12)

        func button(_ title: String, _ label: String, _ action: @escaping () -> Void) -> ClosureButton {
            let control = ClosureButton(title: title, target: nil, action: nil)
            control.bezelStyle = .rounded
            control.handler = action
            control.setAccessibilityLabel(label)
            return control
        }

        let choose = button("Choose file…", "Choose the document that holds your working agreement") {
            [weak self] in self?.chooseFile()
        }
        let usePath = button("Use this path", "Use the path typed above") {
            [weak self] in self?.useTypedPath()
        }
        let open = button("Open for editing", "Open the selected document in a text editor") {
            [weak self] in self?.openForEditing()
        }
        let reveal = button("Reveal in Finder", "Show the selected document in the Finder") {
            [weak self] in self?.revealInFinder()
        }
        let clear = button("Clear selection", "Forget the selected document. The file is not deleted") {
            [weak self] in self?.clearSelection()
        }
        let close = button("Close", "Close this window") { [weak self] in self?.close() }
        close.keyEquivalent = "\r"
        openButton = open
        revealButton = reveal
        clearButton = clear

        let actions = NSStackView(views: [choose, usePath, open, reveal, clear, close])
        actions.orientation = .horizontal
        actions.spacing = 8

        let stack = NSStackView(views: [headline, pathLabel, detailLabel, explanation, pathField,
                                        actions, statusLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            pathField.widthAnchor.constraint(equalToConstant: 520),
        ])
        window.contentView = content
        self.window = window
    }

    // MARK: - For the UI check

    var debugHeadline: String { headline.stringValue }
    var debugStatus: String { statusLabel.stringValue }
    var debugDetail: String { detailLabel.stringValue }
    var debugSelection: String? { reading.selectedPath }
    var debugOpenEnabled: Bool { openButton?.isEnabled ?? false }
    var debugClearEnabled: Bool { clearButton?.isEnabled ?? false }
    func debugPrepare(selection: String?) { build(); refresh(selection: selection) }
    /// The titlebar close, driven the way a person drives it — through the window, so the delegate
    /// callback is the thing under test rather than a method called directly.
    func debugNativeClose() { window?.performClose(nil) }
    func debugType(_ path: String) { pathField.stringValue = path }
}
