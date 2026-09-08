import Foundation

/// Did the turn end by handing something back to the person?
///
/// A turn can finish in two quite different ways, and Agent Warden has been treating them as one.
/// "I have done the thing, nothing is needed" is news. "Here is what I need you to decide" is a
/// request — and when the same turn also left a shell running, the background rule quite correctly
/// suppressed the generic completion and the request went with it. That is the defect this closes.
///
/// **What counts, deliberately narrowly.** Only a *dedicated final handoff line*: a line whose own
/// text begins with `I need from you:` (Markdown emphasis around it is fine, because that is how it
/// is normally written) and which asks for something. Not a question mark anywhere in the text, not
/// a suggestion in a paragraph, not a line inside a code fence or a block quote. The point is to
/// recognise a convention someone is deliberately following, not to infer intent from prose.
///
/// **What must stay quiet.** `I need from you: nothing` — and its relatives — is the *routine* way
/// these replies end. Treating it as a request would make the app cry wolf on nearly every turn,
/// which is worse than the bug being fixed. The same goes for a bare label with nothing after it, a
/// continuation that declines, anything oversized or malformed, and anything coming from a
/// subagent: a subagent's closing message is not the parent asking you anything.
///
/// **What this is not, and will not become without a separate design.** It does not detect requests
/// in free prose — a paragraph that happens to want something is not recognised, deliberately. It
/// does not look at transcripts, and it cannot recover a request that was missed before it existed.
/// Both would be different features with different risks; neither is smuggled in here.
///
/// **Privacy.** The text is read from `Stop.last_assistant_message` — the field Claude Code's hook
/// documentation provides for exactly this, and recommends over reading the transcript, because the
/// final text may not be on disk yet. It is parsed **in memory**. Nothing from it reaches disk
/// unless the user has switched `includeHookMessages` on, and even then only a short excerpt of the
/// request itself.
public enum FinalHandoff {
    /// The marker, matched case-insensitively after Markdown decoration is stripped.
    static let marker = "i need from you"

    /// Longer than this and we do not look. A final message is a paragraph or two; anything the size
    /// of a transcript is either not what we think it is, or not worth the risk of misreading.
    public static let maximumBytes = 16 * 1024
    /// The most we would ever keep, and only with `includeHookMessages` on.
    public static let maximumExcerpt = 120
    /// Every axis of this parse is bounded. Lines, as well as bytes.
    public static let maximumLines = 400
    /// How far past a bare label we will look for the request it introduces.
    public static let maximumBlankLinesBeforeContinuation = 1

    /// The routine ways of saying "nothing is needed". These end most replies, and none of them is
    /// a request. Compared after punctuation and decoration are stripped.
    static let nothingPrefixes = [
        "nothing", "none", "no action", "no decision", "nada", "n/a", "na",
        "not a thing", "no input", "no reply", "no response",
    ]

    /// Words that routinely finish one of those phrases — "no action **needed**", "nothing
    /// **required**", "nothing **further**". An explicit, closed list: recognising a fixed set of
    /// endings is not the same as understanding a sentence, and understanding sentences is exactly
    /// what this parser refuses to attempt. `none **of** these options work` is not in it, so that
    /// stays a request.
    static let nothingQualifiers = [
        "needed", "required", "necessary", "further", "else", "more",
        "at all", "for now", "from you", "right now", "yet", "here",
    ]
    /// How many of those may be chained — "nothing needed at all" is two, and that is plenty.
    static let maximumNothingQualifiers = 3

    /// What a final message asked for, if anything.
    public struct Reading: Sendable, Equatable {
        /// True only for a dedicated handoff line that asks for something.
        public var asksForSomething: Bool
        /// The request itself, already bounded. Kept in memory; persisted only on opt-in.
        public var excerpt: String?
        /// Why the answer is what it is, for the record and for a reviewer.
        public var reason: Reason
        /// The request asks the **user** to try, test, review or accept something.
        ///
        /// A different kind of wait from "which option shall I use". Nothing the agent does next —
        /// a shell finishing, a monitor ticking, the parent carrying on by itself — is the user
        /// having looked at the work. Only the user responding, or explicitly dismissing it,
        /// closes one of these.
        public var awaitsUserAcceptance: Bool = false

        public enum Reason: String, Sendable, Equatable {
            case asked
            case noMarker
            case explicitlyNothing
            case insideCodeOrQuote
            /// A label with nothing after it. A heading is not a request.
            case emptyRequest
            /// The label was followed by something this parser will not interpret — a fence, a
            /// quote, another label. Quiet by choice rather than by guess.
            case unsupportedShape
            case tooLarge
            case empty
        }

        static let quiet = Reading(asksForSomething: false, excerpt: nil, reason: .noMarker)

        static func asked(_ text: some StringProtocol) -> Reading {
            Reading(asksForSomething: true,
                    excerpt: String(text.prefix(FinalHandoff.maximumExcerpt)), reason: .asked,
                    awaitsUserAcceptance: FinalHandoff.asksForAcceptance(String(text)))
        }
    }

    /// Words that mean "you try it": the user is being handed something to check.
    ///
    /// Matched on the request the footer already isolated — never by scanning prose, which stays
    /// out of scope. A question mark is not required and never was: "UAT steps are here" and
    /// "please test the new flow" are requests in every sense that matters to the person reading
    /// them, and treating them as statements is how an acceptance checkpoint gets walked past.
    static let acceptanceWords: [String] = [
        "uat", "user acceptance", "acceptance test", "acceptance testing", "test", "tests",
        "testing", "try", "review", "reviewing", "check", "confirm", "verify", "accept",
        "sign off", "walk through", "run through", "look",
    ]

    /// Phrases that are themselves an address to the reader. "Have a look" is not a topic.
    static let handBackPhrases: [String] = [
        "have a look", "take a look", "over to you", "steps are here", "steps below",
        // "for you to" is deliberately absent: it matches any sentence that *quotes* a hand-back —
        // "waiting for you to test it" inside a status report — and a report about a pending
        // checkpoint must not create another one.
        "ready for your", "ready for you", "handed to you", "back to you",
        // "let me know" and its cousins are deliberately absent. They close an enormous share of
        // ordinary turns — "done, let me know if you have questions" — and treating a sign-off as
        // a hand-back put a row nobody was waiting on into the count, which only the user could
        // then clear. A genuine request still carries "please" or an imperative of its own.
        "sign off", "your acceptance",
    ]

    /// Verbs that, at the start of a sentence, are an instruction rather than a description.
    static let imperativeVerbs: [String] = [
        "test", "try", "review", "check", "confirm", "verify", "run", "open", "have", "take",
        "walk", "accept", "please",
    ]

    /// A report of testing already done, rather than a request to do it.
    static let pastMarkers: [String] = [
        "i ran", "i have run", "i tested", "i have tested", "i reviewed", "i have reviewed",
        "we ran", "we tested", "we already", "was completed", "were completed", "has been done",
        "have been done", "has been tested", "already reviewed", "already tested", "passed",
        "completed last", "was done",
        // Explicitly temporal: a sentence anchored to a past moment is a report of what happened,
        // not a request about now. Judged per sentence, so a later "please test this" in the same
        // message is unaffected.
        "yesterday", "last week", "last night", "earlier today", "earlier i", "previously",
        "i asked you", "you accepted", "you confirmed", "you signed off",
    ]

    /// Testing that belongs to some later moment. A plan is not a checkpoint.
    static let futureMarkers: [String] = [
        "will need", "will follow", "will write", "will be needed", "we will", "i will",
        "once this", "once it", "once merged", "after the", "after this", "later we",
        "next up", "next time", "in a follow", "eventually", "at some point", "when this is",
    ]

    /// Does this request hand the work to the user to try?
    ///
    /// Judged **per sentence**, not over the whole passage. "The automated tests passed; please
    /// test the UI" is a current request that happens to sit next to a report, and suppressing it
    /// because the word *passed* appears somewhere in the message would lose exactly the handoffs
    /// this exists to catch.
    static func asksForAcceptance(_ request: String) -> Bool {
        sentences(of: request).contains(where: isCurrentAcceptanceSentence)
    }

    /// One sentence, judged on its own — and judged on **two** things, not one.
    ///
    /// A topic word is not a request. "The endpoint accepts JSON" and "acceptance criteria are in
    /// the ticket" are about acceptance; neither hands anything to anybody. And substring matching
    /// was worse than loose: *sit**uat**ion* contains "uat", so "the situation is resolved" became
    /// a sticky checkpoint nobody could clear. So a sentence must carry
    ///
    /// 1. an acceptance word, matched on **word boundaries**, and
    /// 2. something that addresses the reader — "please", a second person, an opening imperative,
    ///    or a phrase like "have a look" that is inherently directed at them —
    ///
    /// and must not be a report of the past, a plan for the future, or a negation.
    static func isCurrentAcceptanceSentence(_ sentence: String) -> Bool {
        let text = sentence.lowercased().trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return false }
        let words = FinalHandoff.words(of: text)
        guard !words.isEmpty else { return false }

        // **Every** list here is matched on word boundaries — the hand-back phrases and the
        // refusals as much as the acceptance words. Half a fix is its own bug: "carryover to you"
        // contains "over to you", and "bypassed" contains "passed", so a substring check on either
        // side invents a checkpoint or silences a real one.
        guard acceptanceWords.contains(where: { contains(phrase: $0, in: words) })
            || handBackPhrases.contains(where: { contains(phrase: $0, in: words) }) else {
            return false
        }
        guard addressesTheReader(text, words: words) else { return false }

        // "No UAT is required", "nothing to test here" — the sentence carries the words and says
        // the opposite.
        guard !negationMarkers.contains(where: { contains(phrase: $0, in: words) }) else { return false }
        guard !pastMarkers.contains(where: { contains(phrase: $0, in: words) }) else { return false }
        guard !futureMarkers.contains(where: { contains(phrase: $0, in: words) }) else { return false }
        return true
    }

    /// Is this sentence **asking** the person reading it to do something?
    ///
    /// A mention of them is not a request about them. "Your UAT of the panel is still open" is a
    /// status report; treating it as a new hand-back is how a message *about* a pending checkpoint
    /// created another one — which then could not be cleared, because only the user clears those.
    /// So a bare "you"/"your" no longer counts on its own; what counts is an actual address:
    ///
    /// - a hand-back phrase ("over to you", "ready for your", "steps are here"),
    /// - the word "please",
    /// - or an opening imperative **with something to act on** — "test the new flow", not "test".
    static func addressesTheReader(_ text: String, words: [String]) -> Bool {
        if handBackPhrases.contains(where: { contains(phrase: $0, in: words) }) { return true }
        if words.contains("please") { return true }
        // An opening imperative: "Test the flow", "Review the screens", "Try it". Taken from the
        // raw first token, so "Check-in is at four" is the noun it obviously is — and a verb with
        // nothing after it is a label, not an instruction.
        let firstToken = text.split(separator: " ").first.map(String.init) ?? ""
        let bare = firstToken.trimmingCharacters(in: CharacterSet(charactersIn: ",:;"))
        if imperativeVerbs.contains(bare), words.count > 1 { return true }
        return false
    }

    /// Lowercased words, punctuation stripped. `UAT-adjacent` is two words, and neither is `uat`
    /// standing on its own as a request — the reader check settles that case anyway.
    static func words(of text: String) -> [String] {
        text.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
    }

    /// Does this word-sequence appear as whole words?
    static func contains(phrase: String, in words: [String]) -> Bool {
        let needle = phrase.split(separator: " ").map(String.init)
        guard !needle.isEmpty, words.count >= needle.count else { return false }
        for start in 0...(words.count - needle.count) where Array(words[start..<(start + needle.count)]) == needle {
            return true
        }
        return false
    }

    /// Split into sentences, bounded. Newlines end a sentence too: a heading followed by numbered
    /// steps is several statements, whatever punctuation it uses.
    static func sentences(of text: String) -> [String] {
        var parts: [String] = []
        var current = ""
        for character in text.prefix(maximumBytes) {
            if character == "." || character == "!" || character == "?" || character == "\n"
                || character == ";" {
                if !current.trimmingCharacters(in: .whitespaces).isEmpty { parts.append(current) }
                current = ""
                if parts.count >= maximumLines { break }
            } else {
                current.append(character)
            }
        }
        if !current.trimmingCharacters(in: .whitespaces).isEmpty { parts.append(current) }
        return parts
    }

    /// Sentences that use the words and mean the opposite.
    static let negationMarkers: [String] = [
        "no uat", "not needed", "no need", "nothing to test", "not required", "no testing",
        "isn't needed", "is not needed", "don't need", "do not need", "no review needed",
    ]

    /// A **current** hand-back found outside the dedicated footer.
    ///
    /// The footer is the precise signal and stays the primary one. But people — and agents — hand
    /// work over in ordinary sentences: "UAT steps are here", "please test the updated
    /// functionality". Refusing to see those because they lack a label would mean the checkpoint
    /// this whole feature exists for is missed in exactly the cases that were asked for.
    ///
    /// Bounded and conservative: fenced code and quoted lines are skipped exactly as the footer
    /// parser skips them, each sentence is judged alone, and past, future and negated sentences are
    /// refused. It does not read anything else out of the message — no summarising, no topic
    /// detection, no scanning for questions in prose.
    public static func readStandaloneAcceptance(_ message: String?) -> Reading {
        guard let message, !message.isEmpty else {
            return Reading(asksForSomething: false, excerpt: nil, reason: .empty)
        }
        guard message.utf8.count <= maximumBytes else {
            return Reading(asksForSomething: false, excerpt: nil, reason: .tooLarge)
        }

        var openFence: (character: Character, length: Int)?
        for rawLine in message.components(separatedBy: .newlines).prefix(maximumLines) {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            if let marker = fenceMarker(trimmed) {
                if let open = openFence {
                    if marker.character == open.character, marker.length >= open.length {
                        openFence = nil
                    }
                } else {
                    openFence = (marker.character, marker.length)
                }
                continue
            }
            if openFence != nil { continue }               // inside a fence: an example, not an ask
            if trimmed.hasPrefix(">") { continue }         // quoted: somebody else's words
            guard let found = sentences(of: trimmed).first(where: isCurrentAcceptanceSentence) else {
                continue
            }
            return Reading(asksForSomething: true,
                           excerpt: String(found.trimmingCharacters(in: .whitespaces)
                                            .prefix(maximumExcerpt)),
                           reason: .asked, awaitsUserAcceptance: true)
        }
        return .quiet
    }

    /// Read a final assistant message. Never throws, never blocks, never touches disk.
    public static func read(_ message: String?) -> Reading {
        guard let message, !message.isEmpty else {
            return Reading(asksForSomething: false, excerpt: nil, reason: .empty)
        }
        guard message.utf8.count <= maximumBytes else {
            return Reading(asksForSomething: false, excerpt: nil, reason: .tooLarge)
        }

        // Bounded on every axis: total size above, and line count here. A message with tens of
        // thousands of lines is not a footer, whatever it contains.
        let lines = message.components(separatedBy: .newlines).prefix(maximumLines)
        var openFence: (character: Character, length: Int)?
        var sawMarkerInCodeOrQuote = false

        for (index, rawLine) in lines.enumerated() {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)

            // Fenced code, tracked properly. A fence is closed only by one of the **same character**
            // and at least the same length — so ``` inside a ```` block is content, not a closer,
            // and `~~~` never closes a backtick fence.
            if let fence = fenceMarker(trimmed) {
                if let open = openFence {
                    // Same character, at least as long, and **nothing after the delimiter**.
                    if fence.character == open.character, fence.length >= open.length, fence.bare {
                        openFence = nil
                    }
                    // Otherwise it is a fence *inside* a block: still code.
                } else {
                    openFence = (fence.character, fence.length)
                }
                continue
            }
            if openFence != nil {
                if undecorated(trimmed).hasPrefix(marker) { sawMarkerInCodeOrQuote = true }
                continue
            }
            // A quoted line is someone else's words. An indented block, or a line wrapped in
            // backticks, is a code example. None of them is this turn asking for anything.
            if isQuotedOrCode(raw: rawLine, trimmed: trimmed) {
                if undecorated(trimmed).hasPrefix(marker) { sawMarkerInCodeOrQuote = true }
                continue
            }

            let line = undecorated(trimmed)
            guard line.hasPrefix(marker) else { continue }

            // The marker has to introduce its own line, as a label: `I need from you:`. Without the
            // colon it is a sentence that happens to contain the phrase — "I need from your review
            // notes" is prose, not a handoff.
            let afterMarker = String(line.dropFirst(marker.count))
            let labelled = afterMarker.drop { "*_ ".contains($0) }
            guard labelled.first == ":" else { continue }

            let remainder = String(labelled.dropFirst())
                .trimmingCharacters(in: CharacterSet(charactersIn: " :*_-—–\t"))
            if !remainder.isEmpty {
                if isNothing(remainder) {
                    return Reading(asksForSomething: false, excerpt: nil, reason: .explicitlyNothing)
                }
                return Reading.asked(remainder)
            }

            // A label with nothing after it. The request may be on the next line — that is a normal
            // way to write it — but a bare label is **not** a request, and a continuation that says
            // "nothing" is still nothing. Anything else on that next line (a fence, a quote, another
            // marker, more label) is not something this parser will interpret, so it stays quiet.
            return continuation(after: index, in: lines)
        }

        if sawMarkerInCodeOrQuote {
            return Reading(asksForSomething: false, excerpt: nil, reason: .insideCodeOrQuote)
        }
        return .quiet
    }

    /// What follows a bare `I need from you:` label, if it is plainly the request.
    private static func continuation(after index: Int, in lines: ArraySlice<String>) -> Reading {
        // One line of lookahead, past blanks. More than that and the connection to the label is a
        // guess, which is the thing this parser does not do.
        var seen = 0
        for rawLine in lines.dropFirst(index + 1) {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                seen += 1
                if seen > maximumBlankLinesBeforeContinuation { break }
                continue
            }
            if fenceMarker(trimmed) != nil || isQuotedOrCode(raw: rawLine, trimmed: trimmed) {
                return Reading(asksForSomething: false, excerpt: nil, reason: .unsupportedShape)
            }
            let text = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: " *_-—–\t"))
            if text.isEmpty || undecorated(trimmed).hasPrefix(marker) {
                return Reading(asksForSomething: false, excerpt: nil, reason: .unsupportedShape)
            }
            if isNothing(text) {
                return Reading(asksForSomething: false, excerpt: nil, reason: .explicitlyNothing)
            }
            return Reading.asked(text)
        }
        // The label was the last thing in the message. A label is not a request.
        return Reading(asksForSomething: false, excerpt: nil, reason: .emptyRequest)
    }

    /// A fence: its character, its length, and whether anything follows the delimiter.
    ///
    /// The distinction matters. An *opening* fence may carry an info string — ```` ```python ````.
    /// A *closing* one may not: `` ```python `` inside a block opens a nested example, it does not
    /// end the outer one. Without this, a code sample containing a second fence ended the block
    /// early and the lines after it were read as prose.
    static func fenceMarker(_ trimmed: String) -> (character: Character, length: Int, bare: Bool)? {
        guard let first = trimmed.first, first == "`" || first == "~" else { return nil }
        let run = trimmed.prefix { $0 == first }.count
        guard run >= 3 else { return nil }
        let after = trimmed.dropFirst(run).trimmingCharacters(in: .whitespaces)
        return (first, run, after.isEmpty)
    }

    /// Quoted, indented, or wrapped in inline backticks — all of them examples rather than asks.
    static func isQuotedOrCode(raw: String, trimmed: String) -> Bool {
        if trimmed.hasPrefix(">") { return true }
        if raw.hasPrefix("    ") || raw.hasPrefix("\t") { return true }
        // `I need from you: …` in backticks is a quotation of the convention, not a use of it.
        if trimmed.hasPrefix("`") { return true }
        return false
    }

    /// Strip the Markdown a footer is normally written with, and lower-case it. Emphasis around the
    /// marker is expected — `**I need from you:**` is the usual form — so it cannot be what decides.
    static func undecorated(_ line: String) -> String {
        var text = Substring(line)
        // Repeatedly, because a quoted footer arrives as `> **I need from you:** …` — one pass
        // would strip the angle bracket and stop at the space.
        while let first = text.first, "*_#>`\t ".contains(first) { text = text.dropFirst() }
        return String(text).lowercased()
    }

    /// Is this one of the routine ways of saying nothing is needed?
    static func isNothing(_ remainder: String) -> Bool {
        var text = remainder.lowercased()
        while let first = text.first, "*_`\"'“‘".contains(first) { text.removeFirst() }
        text = text.trimmingCharacters(in: .whitespaces)
        return nothingPrefixes.contains { prefix in
            guard text.hasPrefix(prefix) else { return false }
            return endsTheThought(text.dropFirst(prefix.count))
        }
    }

    /// Has the phrase finished, allowing for the handful of words that routinely finish it?
    ///
    /// "nothing", "nothing.", "nothing — carry on", "no action needed.", "nothing required" all say
    /// the same thing. "none of these options work, pick one" does not: `of` is not one of the
    /// endings, and a bare space with more sentence after it is where a request begins.
    static func endsTheThought(_ rest: Substring) -> Bool {
        var text = rest
        for _ in 0...maximumNothingQualifiers {
            let trimmed = text.drop { $0 == " " }
            guard let next = trimmed.first else { return true }      // the phrase simply ended
            if ".,;:—–-!…".contains(next) { return true }            // punctuation, then an aside
            guard let qualifier = nothingQualifiers.first(where: { candidate in
                guard trimmed.hasPrefix(candidate) else { return false }
                let after = trimmed.dropFirst(candidate.count).first
                return after == nil || after == " " || ".,;:—–-!…".contains(after!)
            }) else { return false }                                 // an ordinary word: a request
            text = trimmed.dropFirst(qualifier.count)
        }
        return false
    }
}
