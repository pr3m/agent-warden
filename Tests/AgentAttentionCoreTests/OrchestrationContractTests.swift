import Foundation
import Testing
@testable import AgentAttentionCore

/// A scratch directory per test. Nothing here touches a real contract, a real config, or the
/// installed app's data — and no test writes to a document it is reading.
/// `realpath`, which is what the reader uses — `resolvingSymlinksInPath` leaves `/var` alone on
/// macOS, so comparing against it would be testing Foundation rather than the reader.
private func canonical(_ path: String) -> String {
    guard let resolved = realpath(path, nil) else { return path }
    defer { free(resolved) }
    return String(cString: resolved)
}

private struct Scratch {
    let root: URL

    init() {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("warden-contract-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func remove() { try? FileManager.default.removeItem(at: root) }

    @discardableResult
    func write(_ name: String, _ contents: String) -> URL {
        let url = root.appendingPathComponent(name)
        try? Data(contents.utf8).write(to: url)
        return url
    }

    @discardableResult
    func write(_ name: String, bytes: Data) -> URL {
        let url = root.appendingPathComponent(name)
        try? bytes.write(to: url)
        return url
    }
}

/// Reading the agreement: what it says, and — more often — why it cannot say anything.
@Suite("Orchestration contract")
struct OrchestrationContractTests {
    @Test("Nothing chosen is a fact, not a fault")
    func noSelection() {
        for selection in [nil, "", "   "] as [String?] {
            let reading = OrchestrationContract.read(selection: selection, includeContent: true)
            #expect(reading.availability == .noSelection)
            #expect(reading.content == nil)
            #expect(reading.revision == nil)
        }
    }

    @Test("A chosen document is read whole, with a revision over its exact bytes")
    func readsADocument() {
        let scratch = Scratch(); defer { scratch.remove() }
        let file = scratch.write("agreement.md", "# Agreement\n\nUser sets goals.\n")

        let reading = OrchestrationContract.read(selection: file.path, includeContent: true)

        #expect(reading.availability == .available)
        #expect(reading.isUsable)
        #expect(reading.content == "# Agreement\n\nUser sets goals.\n")
        #expect(reading.sizeBytes == 30)
        #expect(reading.revision?.count == 64)
        #expect(reading.modifiedAt != nil)
        #expect(reading.resolvedPath == canonical(file.path))
    }

    @Test("Metadata is not the body: asking about it does not hand it over")
    func metadataDoesNotIncludeContent() {
        let scratch = Scratch(); defer { scratch.remove() }
        let file = scratch.write("agreement.md", "secret working agreement")

        let metadata = OrchestrationContract.read(selection: file.path, includeContent: false)
        #expect(metadata.availability == .available)
        #expect(metadata.content == nil, "a query about the document is not a request for it")
        #expect(metadata.revision != nil, "but it is still enough to notice a change")
    }

    @Test("An edit that keeps the same size and second still changes the revision")
    func sameSizeEditIsDetected() throws {
        let scratch = Scratch(); defer { scratch.remove() }
        let file = scratch.write("agreement.md", "decision: alpha")

        let before = OrchestrationContract.read(selection: file.path, includeContent: false)
        try Data("decision: omega".utf8).write(to: file)          // same length, same second
        let after = OrchestrationContract.read(selection: file.path, includeContent: false)

        #expect(before.sizeBytes == after.sizeBytes)
        #expect(before.revision != after.revision,
                "a size and a timestamp cannot tell one word from another; a digest can")
        #expect(after.availability == .available)
    }

    @Test("Every read is a fresh read — there is no cached agreement to go stale")
    func neverServesACachedCopy() throws {
        let scratch = Scratch(); defer { scratch.remove() }
        let file = scratch.write("agreement.md", "first")
        #expect(OrchestrationContract.read(selection: file.path, includeContent: true).content == "first")

        try Data("second".utf8).write(to: file)
        #expect(OrchestrationContract.read(selection: file.path, includeContent: true).content == "second")
    }

    @Test("A missing file keeps the selection and says what is wrong")
    func missingKeepsTheSelection() throws {
        let scratch = Scratch(); defer { scratch.remove() }
        let file = scratch.write("agreement.md", "here")
        try FileManager.default.removeItem(at: file)

        let reading = OrchestrationContract.read(selection: file.path, includeContent: true)
        #expect(reading.availability == .missing)
        #expect(reading.selectedPath == file.path,
                "a file that is gone today is not a decision to stop having one")
        #expect(reading.content == nil)

        // And restoring it is enough.
        scratch.write("agreement.md", "back")
        #expect(OrchestrationContract.read(selection: file.path, includeContent: true).content == "back")
    }

    @Test("A replaced document reads as the new one, with a new revision")
    func replacementIsVisible() throws {
        let scratch = Scratch(); defer { scratch.remove() }
        let file = scratch.write("agreement.md", "original agreement")
        let first = OrchestrationContract.read(selection: file.path, includeContent: false)

        try FileManager.default.removeItem(at: file)
        scratch.write("agreement.md", "a completely different agreement")
        let second = OrchestrationContract.read(selection: file.path, includeContent: true)

        #expect(second.availability == .available)
        #expect(second.revision != first.revision)
        #expect(second.content == "a completely different agreement")
    }

    @Test("A directory is not a document, and neither is a pipe")
    func nonRegularFilesAreRefused() throws {
        let scratch = Scratch(); defer { scratch.remove() }

        let directory = OrchestrationContract.read(selection: scratch.root.path, includeContent: true)
        #expect(directory.availability == .notRegularFile)

        // A named pipe with nobody writing to it blocks for ever on `open` alone. This must return.
        let fifo = scratch.root.appendingPathComponent("pipe").path
        #expect(mkfifo(fifo, 0o600) == 0)
        let started = Date()
        let reading = OrchestrationContract.read(selection: fifo, includeContent: true)
        #expect(Date().timeIntervalSince(started) < 2, "a pipe nobody writes to must not hang this")
        #expect(reading.availability == .notRegularFile)
        #expect(reading.content == nil)
    }

    @Test("Types a machine could run are refused by name", arguments: [
        "agreement.command", "agreement.sh", "agreement.html", "agreement.js", "agreement.scpt",
    ])
    func runnableTypesAreRefused(_ name: String) {
        let scratch = Scratch(); defer { scratch.remove() }
        let file = scratch.write(name, "echo hello")

        let reading = OrchestrationContract.read(selection: file.path, includeContent: true)
        #expect(reading.availability == .unsupportedType)
        #expect(reading.content == nil)
        #expect(reading.note.contains(name), "the refusal names the file, so it can be acted on")
    }

    @Test("An executable bit is refused even with a friendly extension")
    func executableBitIsRefused() throws {
        let scratch = Scratch(); defer { scratch.remove() }
        let file = scratch.write("agreement.md", "# looks harmless")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)

        let reading = OrchestrationContract.read(selection: file.path, includeContent: true)
        #expect(reading.availability == .unsupportedType)
        #expect(reading.note.contains("executable"))
    }

    @Test("Supported document types are accepted", arguments: [
        "agreement.md", "agreement.markdown", "agreement.txt", "AGREEMENT",
    ])
    func supportedTypesAreAccepted(_ name: String) {
        let scratch = Scratch(); defer { scratch.remove() }
        let file = scratch.write(name, "we agree")
        #expect(OrchestrationContract.read(selection: file.path, includeContent: true).availability
                == .available)
    }

    @Test("Something that is not text is left alone and reported")
    func binaryIsRefused() {
        let scratch = Scratch(); defer { scratch.remove() }
        let bytes = Data([0xFF, 0xFE, 0x00, 0x01, 0xC3, 0x28, 0x80])
        let file = scratch.write("agreement.md", bytes: bytes)

        let reading = OrchestrationContract.read(selection: file.path, includeContent: true)
        #expect(reading.availability == .notText)
        #expect(reading.content == nil, "nothing is lossily converted into something readable")
        #expect(try! Data(contentsOf: file) == bytes, "and the file is exactly as it was")
    }

    @Test("Too large is refused whole — never half an agreement")
    func oversizeIsRefusedWithoutAPartialBody() {
        let scratch = Scratch(); defer { scratch.remove() }
        let big = String(repeating: "x", count: OrchestrationContract.maximumBytes + 1)
        let file = scratch.write("agreement.md", big)

        let reading = OrchestrationContract.read(selection: file.path, includeContent: true)
        #expect(reading.availability == .tooLarge)
        #expect(reading.content == nil)
        #expect(reading.revision == nil, "there is no revision for bytes that were not read")
        #expect(reading.sizeBytes == OrchestrationContract.maximumBytes + 1, "the size is still told")
    }

    @Test("A document exactly at the bound is read")
    func theBoundIsInclusive() {
        let scratch = Scratch(); defer { scratch.remove() }
        let file = scratch.write("agreement.md",
                                 String(repeating: "y", count: OrchestrationContract.maximumBytes))
        let reading = OrchestrationContract.read(selection: file.path, includeContent: true)
        #expect(reading.availability == .available)
        #expect(reading.content?.count == OrchestrationContract.maximumBytes)
    }

    @Test("A selection is a local file, not a location or an instruction", arguments: [
        "https://example.com/agreement.md", "ssh://host/agreement.md",
        "cat /etc/passwd | tee out", "agreement.md; rm -rf ~", "`whoami`.md", "$(pwd)/x.md",
    ])
    func onlyLocalPathsAreAccepted(_ selection: String) {
        let reading = OrchestrationContract.read(selection: selection, includeContent: true)
        #expect(reading.availability == .unsupportedType)
        #expect(reading.content == nil)
    }

    @Test("Reading never writes to the document")
    func readingIsReadOnly() throws {
        let scratch = Scratch(); defer { scratch.remove() }
        let file = scratch.write("agreement.md", "# untouched\n")
        let before = try FileManager.default.attributesOfItem(atPath: file.path)
        let bytes = try Data(contentsOf: file)

        for _ in 0..<5 { _ = OrchestrationContract.read(selection: file.path, includeContent: true) }

        let after = try FileManager.default.attributesOfItem(atPath: file.path)
        #expect(try Data(contentsOf: file) == bytes)
        #expect((before[.modificationDate] as? Date) == (after[.modificationDate] as? Date))
        #expect((before[.size] as? Int) == (after[.size] as? Int))
    }

    // MARK: - Through the configuration

    @Test("The configuration is re-read on every request, not remembered")
    func configurationIsReReadEachTime() throws {
        let scratch = Scratch(); defer { scratch.remove() }
        let first = scratch.write("first.md", "first agreement")
        let second = scratch.write("second.md", "second agreement")
        let configuration = scratch.root.appendingPathComponent("config.json")

        var config = AttentionConfig.default
        config.orchestrationContractPath = first.path
        try config.save(to: configuration)
        #expect(OrchestrationContract.read(configuration: configuration, includeContent: true)
            .content == "first agreement")

        config.orchestrationContractPath = second.path
        try config.save(to: configuration)
        #expect(OrchestrationContract.read(configuration: configuration, includeContent: true)
            .content == "second agreement",
                "a consumer that asked twice must not be told what was true the first time")
    }

    @Test("A configuration that cannot be read is not reported as ‘nothing selected’")
    func unreadableConfigurationIsItsOwnAnswer() throws {
        let scratch = Scratch(); defer { scratch.remove() }
        let configuration = scratch.root.appendingPathComponent("config.json")
        try Data("{ this is not json".utf8).write(to: configuration)

        let reading = OrchestrationContract.read(configuration: configuration, includeContent: true)
        #expect(reading.availability == .configUnreadable)
        #expect(reading.selectedPath == nil)
        #expect(reading.content == nil)
    }

    @Test("A configuration that was never written means nothing is selected")
    func absentConfigurationIsNoSelection() {
        let scratch = Scratch(); defer { scratch.remove() }
        let reading = OrchestrationContract.read(
            configuration: scratch.root.appendingPathComponent("absent.json"), includeContent: true)
        #expect(reading.availability == .noSelection)
    }

    @Test("The selection survives being saved and loaded, and clearing really clears")
    func selectionPersists() throws {
        let scratch = Scratch(); defer { scratch.remove() }
        let configuration = scratch.root.appendingPathComponent("config.json")
        let file = scratch.write("agreement.md", "agreed")

        var config = AttentionConfig.default
        config.orchestrationContractPath = file.path
        config.chimeEnabled = true
        config.snoozeDurationSeconds = 1800
        try config.save(to: configuration)

        var loaded = AttentionConfig.load(from: configuration)
        #expect(loaded.orchestrationContractPath == file.path)
        #expect(loaded.chimeEnabled, "unrelated preferences are untouched by any of this")
        #expect(loaded.snoozeDurationSeconds == 1800)

        loaded.orchestrationContractPath = nil
        try loaded.save(to: configuration)
        let cleared = AttentionConfig.load(from: configuration)
        #expect(cleared.orchestrationContractPath == nil)
        #expect(cleared.chimeEnabled, "and clearing one thing changes nothing else")
        #expect(FileManager.default.fileExists(atPath: file.path),
                "clearing a selection never deletes the document")
    }

    @Test("An existing configuration with no contract key simply has none")
    func olderConfigurationsHaveNoContract() throws {
        let scratch = Scratch(); defer { scratch.remove() }
        let configuration = scratch.root.appendingPathComponent("config.json")
        try Data(#"{ "soundEnabled": true, "snoozeDurationSeconds": 900 }"#.utf8)
            .write(to: configuration)

        let config = AttentionConfig.load(from: configuration)
        #expect(config.orchestrationContractPath == nil)
        #expect(config.snoozeDurationSeconds == 900)
        #expect(AttentionConfig.default.orchestrationContractPath == nil,
                "no vault is assumed, and no path is invented")
    }

    @Test("A blank path is stored as no selection, so there is one way to mean ‘none’")
    func blankIsNormalisedToAbsent() {
        var config = AttentionConfig.default
        config.orchestrationContractPath = "   "
        #expect(config.validated().orchestrationContractPath == nil)
    }

    // MARK: - The second review round

    @Test("A configuration that is a named pipe is refused, not waited on")
    func configurationIsReadWithoutBlocking() {
        let scratch = Scratch(); defer { scratch.remove() }
        let configuration = scratch.root.appendingPathComponent("config.json")
        #expect(mkfifo(configuration.path, 0o600) == 0)

        let started = Date()
        let reading = OrchestrationContract.read(configuration: configuration, includeContent: true)
        #expect(Date().timeIntervalSince(started) < 2, "a query that hangs is worse than one that refuses")
        #expect(reading.availability == .configUnreadable)
    }

    @Test("A selection of the wrong type is ‘we cannot tell’, never ‘there is none’", arguments: [
        #"{ "orchestrationContractPath": 42 }"#,
        #"{ "orchestrationContractPath": true }"#,
        #"{ "orchestrationContractPath": ["/tmp/a.md"] }"#,
        #"{ "orchestrationContractPath": {"path": "/tmp/a.md"} }"#,
    ])
    func aNonStringSelectionIsNotNoSelection(_ contents: String) throws {
        let scratch = Scratch(); defer { scratch.remove() }
        let configuration = scratch.root.appendingPathComponent("config.json")
        try Data(contents.utf8).write(to: configuration)

        let reading = OrchestrationContract.read(configuration: configuration, includeContent: true)
        #expect(reading.availability == .configUnreadable,
                "the tolerant decoder turns this into nil, which would read as a deliberate ‘none’")

        // And the monitor still starts on the same file, which is what the tolerant decoder is for.
        #expect(AttentionConfig.load(from: configuration).orchestrationContractPath == nil)
    }

    @Test("An explicit null, or no key at all, really is no selection", arguments: [
        #"{ "orchestrationContractPath": null }"#, #"{ "soundEnabled": true }"#, "{}",
    ])
    func absentSelectionIsNoSelection(_ contents: String) throws {
        let scratch = Scratch(); defer { scratch.remove() }
        let configuration = scratch.root.appendingPathComponent("config.json")
        try Data(contents.utf8).write(to: configuration)
        #expect(OrchestrationContract.read(configuration: configuration, includeContent: true)
            .availability == .noSelection)
    }

    @Test("A path we are not allowed to look at is unreadable, not missing")
    func permissionDeniedIsNotAbsence() throws {
        let scratch = Scratch(); defer { scratch.remove() }
        let closed = scratch.root.appendingPathComponent("closed")
        try FileManager.default.createDirectory(at: closed, withIntermediateDirectories: true)
        let file = closed.appendingPathComponent("agreement.md")
        try Data("# inside".utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: closed.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700],
                                                       ofItemAtPath: closed.path) }

        let reading = OrchestrationContract.read(selection: file.path, includeContent: true)
        #expect(reading.availability == .unreadable,
                "‘I cannot look’ is not evidence that the agreement was deleted")
        #expect(reading.content == nil)
    }

    @Test("A relative path is refused, because it would mean different files to different callers",
          arguments: ["agreement.md", "./agreement.md", "../agreement.md", "docs/agreement.md"])
    func relativePathsAreRefused(_ selection: String) {
        let reading = OrchestrationContract.read(selection: selection, includeContent: true)
        #expect(reading.availability == .unsupportedType)
        #expect(reading.note.contains("relative"))
        #expect(reading.content == nil)
    }

    @Test("An absolute path, and a tilde path, are both fine")
    func absoluteAndTildePathsAreAccepted() {
        let scratch = Scratch(); defer { scratch.remove() }
        let file = scratch.write("agreement.md", "agreed")
        #expect(OrchestrationContract.read(selection: file.path, includeContent: false)
            .availability == .available)
        // A tilde path that does not exist is *missing*, not refused — it was understood.
        #expect(OrchestrationContract.read(selection: "~/no-such-agreement-\(UUID().uuidString).md",
                                           includeContent: false).availability == .missing)
    }

    @Test("Valid UTF-8 full of control bytes is data, not a document", arguments: [
        "before\u{0}after", "\u{1}\u{2}\u{3}", "text\u{7F}more",
    ])
    func controlPayloadsAreRefused(_ contents: String) {
        let scratch = Scratch(); defer { scratch.remove() }
        let file = scratch.write("agreement.md", contents)

        let reading = OrchestrationContract.read(selection: file.path, includeContent: true)
        #expect(reading.availability == .notText, "a NUL-riddled blob decodes cleanly and is still data")
        #expect(reading.content == nil)
        #expect(reading.revision == nil)
    }

    @Test("Real documents keep their tabs, newlines and Unicode")
    func ordinaryTextIsUntouched() {
        let scratch = Scratch(); defer { scratch.remove() }
        let contents = "# Agreement\n\n\tIndented — “quoted”, café, 日本語, 🎯\r\nline\n"
        let file = scratch.write("agreement.md", contents)

        let reading = OrchestrationContract.read(selection: file.path, includeContent: true)
        #expect(reading.availability == .available)
        #expect(reading.content == contents)
    }

    @Test("A document replaced underneath the read is reported, with no body and no revision")
    func atomicReplacementIsCaught() {
        let scratch = Scratch(); defer { scratch.remove() }
        let file = scratch.write("agreement.md", "the original agreement")
        let replacement = scratch.write("replacement.md", "an entirely different agreement")

        // Deterministic: the swap happens between reading the bytes and checking what they came
        // from, which is exactly the window this guard exists for. No racing threads.
        let reading = OrchestrationContract.read(selection: file.path, includeContent: true,
                                                 afterRead: {
            try? FileManager.default.removeItem(at: file)
            try? FileManager.default.moveItem(at: replacement, to: file)
        })

        #expect(reading.availability == .changedWhileReading,
                "the open descriptor is intact; the path now names something else")
        #expect(reading.content == nil)
        #expect(reading.revision == nil)
    }

    @Test("A symlink pointed elsewhere underneath the read is caught too")
    func symlinkRetargetIsCaught() throws {
        let scratch = Scratch(); defer { scratch.remove() }
        let first = scratch.write("first.md", "the first agreement")
        let second = scratch.write("second.md", "the second agreement")
        let link = scratch.root.appendingPathComponent("agreement.md")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: first)

        let reading = OrchestrationContract.read(selection: link.path, includeContent: true,
                                                 afterRead: {
            try? FileManager.default.removeItem(at: link)
            try? FileManager.default.createSymbolicLink(at: link, withDestinationURL: second)
        })

        #expect(reading.availability == .changedWhileReading)
        #expect(reading.content == nil)
    }

    @Test("An untouched document reads normally through the same seam")
    func theSeamDoesNotBreakTheOrdinaryCase() {
        let scratch = Scratch(); defer { scratch.remove() }
        let file = scratch.write("agreement.md", "unchanged")
        let reading = OrchestrationContract.read(selection: file.path, includeContent: true,
                                                 afterRead: { /* nothing happens */ })
        #expect(reading.availability == .available)
        #expect(reading.content == "unchanged")
    }

    @Test("The path that is checked is the path that is opened", arguments: [
        " agreement.md", "\tagreement.md", "  ./agreement.md", " \n agreement.md ",
    ])
    func whitespaceCannotSmuggleARelativePathThrough(_ selection: String) {
        // Trimming for the check and expanding the original for the read let a leading space carry
        // a relative path past the guard, where it resolved against whichever directory asked.
        let reading = OrchestrationContract.read(selection: selection, includeContent: true)
        #expect(reading.availability == .unsupportedType)
        #expect(reading.content == nil)
        #expect(reading.resolvedPath == nil, "nothing was opened at all")
    }

    @Test("A leading space in front of an absolute path is tidied, not obeyed")
    func surroundingWhitespaceIsNormalisedNotRejected() {
        let scratch = Scratch(); defer { scratch.remove() }
        let file = scratch.write("agreement.md", "agreed")

        let reading = OrchestrationContract.read(selection: "  \(file.path)  ", includeContent: true)
        #expect(reading.availability == .available, "the path is real; the whitespace is not part of it")
        #expect(reading.resolvedPath == canonical(file.path))
        #expect(reading.content == "agreed")
    }

    @Test("A tilde that does not resolve is refused, not reported as missing", arguments: [
        "~nosuchuser-8f3a/Agreement.md", "~nobody-here/notes/agreement.md",
    ])
    func anUnresolvedTildeIsNotAbsolute(_ selection: String) {
        let reading = OrchestrationContract.read(selection: selection, includeContent: true)
        #expect(reading.availability == .unsupportedType,
                "‘missing’ would say the file was deleted; it was never an absolute path at all")
        #expect(reading.note.contains("absolute path"))
        #expect(reading.resolvedPath == nil)
    }

    @Test("A tilde that does resolve is treated as the absolute path it names")
    func aResolvableTildeIsAccepted() {
        let missing = OrchestrationContract.read(selection: "~/no-such-agreement-\(UUID().uuidString).md",
                                                 includeContent: false)
        #expect(missing.availability == .missing, "understood, and simply not there")
    }

    @Test("The validated path is exactly what the reader hands on", arguments: [
        (" /tmp/agreement.md", "/tmp/agreement.md"),
        ("/tmp/agreement.md ", "/tmp/agreement.md"),
    ])
    func theVerdictCarriesTheNormalisedPath(_ testCase: (input: String, expected: String)) {
        guard case .path(let path) = OrchestrationContract.absolutePath(testCase.input) else {
            Issue.record("an absolute path should be accepted"); return
        }
        #expect(path == testCase.expected, "one string is validated, and that same string is opened")
    }

    // MARK: - Storing a selection

    @Test("A saved selection is applied; every other preference comes with it")
    func storingKeepsEverythingElse() throws {
        let scratch = Scratch(); defer { scratch.remove() }
        let configuration = scratch.root.appendingPathComponent("config.json")
        let file = scratch.write("agreement.md", "agreed")

        var current = AttentionConfig.default
        current.chimeEnabled = true
        current.snoozeDurationSeconds = 1800
        try current.save(to: configuration)

        guard case .saved(let updated) = ContractSelection.store(file.path, current: current,
                                                                 to: configuration) else {
            Issue.record("a writable configuration should save"); return
        }
        #expect(updated.orchestrationContractPath == file.path)
        #expect(updated.chimeEnabled && updated.snoozeDurationSeconds == 1800)
        #expect(AttentionConfig.load(from: configuration).orchestrationContractPath == file.path)
    }

    @Test("A selection that cannot be written changes nothing — on disk or in memory")
    func aFailedSaveIsRolledBackByConstruction() throws {
        let scratch = Scratch(); defer { scratch.remove() }
        let configuration = scratch.root.appendingPathComponent("config.json")
        let file = scratch.write("agreement.md", "agreed")

        var current = AttentionConfig.default
        current.orchestrationContractPath = nil
        try current.save(to: configuration)
        let before = try Data(contentsOf: configuration)

        // Unwritable: the directory the file lives in is closed.
        try FileManager.default.setAttributes([.posixPermissions: 0o500],
                                              ofItemAtPath: scratch.root.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700],
                                                       ofItemAtPath: scratch.root.path) }

        let outcome = ContractSelection.store(file.path, current: current, to: configuration)
        guard case .failed(let message) = outcome else {
            Issue.record("an unwritable configuration must not report success"); return
        }
        #expect(message.contains("could not be saved"))
        #expect(current.orchestrationContractPath == nil,
                "the configuration the caller holds was never changed, so there is nothing to undo")
        #expect(try Data(contentsOf: configuration) == before, "and the file is byte-for-byte as it was")
    }

    @Test("Clearing goes through the same path, and keeps the rest")
    func clearingIsStoredTheSameWay() throws {
        let scratch = Scratch(); defer { scratch.remove() }
        let configuration = scratch.root.appendingPathComponent("config.json")
        let file = scratch.write("agreement.md", "agreed")

        var current = AttentionConfig.default
        current.orchestrationContractPath = file.path
        current.speechEnabled = true
        try current.save(to: configuration)

        guard case .saved(let updated) = ContractSelection.store(nil, current: current,
                                                                 to: configuration) else {
            Issue.record("clearing should save"); return
        }
        #expect(updated.orchestrationContractPath == nil)
        #expect(updated.speechEnabled)
        #expect(FileManager.default.fileExists(atPath: file.path), "and the document is untouched")
    }

    // MARK: - Opening, and refusing to

    @Test("Only a document that was actually read may be opened")
    func openingNeedsAGoodReading() {
        let scratch = Scratch(); defer { scratch.remove() }
        let file = scratch.write("agreement.md", "# fine")

        let good = OrchestrationContract.read(selection: file.path, includeContent: false)
        guard case .allowed(let path) = OrchestrationContract.openDecision(for: good) else {
            Issue.record("a readable document should be openable"); return
        }
        #expect(path == canonical(file.path))
    }

    @Test("Everything else is refused, by name", arguments: [
        ContractAvailability.noSelection, .missing, .notRegularFile, .unsupportedType,
        .tooLarge, .notText, .unreadable, .changedWhileReading, .configUnreadable,
    ])
    func openingIsRefusedForEverythingElse(_ availability: ContractAvailability) {
        let reading = ContractReading(availability: availability, selectedPath: "/tmp/x.md",
                                      resolvedPath: "/tmp/x.md", readAt: Date(), note: "note")
        guard case .refused = OrchestrationContract.openDecision(for: reading) else {
            Issue.record("\(availability) must not be openable"); return
        }
    }

    @Test("A file that would run is never openable, whatever the chooser allowed through")
    func runnableFilesAreNeverOpenable() {
        let scratch = Scratch(); defer { scratch.remove() }
        let file = scratch.write("agreement.command", "#!/bin/sh\necho no\n")

        let reading = OrchestrationContract.read(selection: file.path, includeContent: false)
        guard case .refused(let why) = OrchestrationContract.openDecision(for: reading) else {
            Issue.record("a .command file must never be opened"); return
        }
        #expect(why.contains("not a type this will open"))
    }
}

/// The contrast arithmetic the readability check measures with. Small, and worth pinning: a check
/// that computes the wrong ratio would pass a surface nobody can read.
@Suite("Contrast")
struct ContrastTests {
    @Test("Black on white is the maximum, and a colour on itself is the minimum")
    func extremes() {
        #expect(abs(Contrast.ratio((0, 0, 0), (1, 1, 1)) - 21) < 0.01)
        #expect(abs(Contrast.ratio((0.5, 0.5, 0.5), (0.5, 0.5, 0.5)) - 1) < 0.0001)
    }

    @Test("It is symmetric — which colour is the text does not change the ratio")
    func symmetry() {
        let a = (red: 0.13, green: 0.13, blue: 0.13)
        let b = (red: 0.82, green: 0.82, blue: 0.82)
        #expect(abs(Contrast.ratio(a, b) - Contrast.ratio(b, a)) < 0.0001)
    }

    @Test("A known pair matches the published value")
    func knownValue() {
        // #767676 on white is the canonical 4.54:1 example from the WCAG material.
        let grey = 0x76 / 255.0
        let ratio = Contrast.ratio((grey, grey, grey), (1, 1, 1))
        #expect(abs(ratio - 4.54) < 0.05)
    }

    @Test("The floors are the published ones")
    func floors() {
        #expect(Contrast.textFloor == 4.5)
        #expect(Contrast.controlFloor == 3.0)
    }

    @Test("Light grey on a light plate fails, which is the case this exists to catch")
    func theFailingCase() {
        // What the panel looked like when the plate took its colour from a white page behind it.
        #expect(Contrast.ratio((0.82, 0.82, 0.82), (0.9, 0.9, 0.9)) < Contrast.textFloor)
        // And what it looks like now.
        #expect(Contrast.ratio((0.82, 0.82, 0.82), (0.13, 0.13, 0.13)) > Contrast.textFloor)
    }
}
