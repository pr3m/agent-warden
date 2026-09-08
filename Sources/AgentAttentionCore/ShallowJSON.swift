import Foundation

/// Pulls a handful of top-level string fields out of a JSON object without building the whole tree.
///
/// A `PostToolUse` payload carries `tool_output`, which can be megabytes. Parsing that into a
/// dictionary costs real time on every tool call and we would throw all of it away — this scanner
/// does the same job in one pass over the raw bytes.
///
/// It tracks nesting depth, so a `cwd` buried inside `tool_input` cannot be mistaken for the real
/// one. Values are unescaped by `JSONSerialization`, so escapes and Unicode stay correct.
public enum ShallowJSON {
    /// Payloads at or below this size take the ordinary, fully-validating parse.
    public static let fullParseLimit = 64 * 1024

    private static let quote: UInt8 = 0x22
    private static let backslash: UInt8 = 0x5C
    private static let colon: UInt8 = 0x3A
    private static let openBrace: UInt8 = 0x7B
    private static let closeBrace: UInt8 = 0x7D
    private static let openBracket: UInt8 = 0x5B
    private static let closeBracket: UInt8 = 0x5D

    public static func topLevelStrings(from data: Data, keys: Set<String>) -> [String: String] {
        guard !data.isEmpty else { return [:] }
        // Scanning through `Data`'s subscript costs more than the parse it replaces; the raw
        // buffer is what makes this worth doing at all.
        return data.withUnsafeBytes { raw -> [String: String] in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return [:] }
            return scan(base: base, count: raw.count, keys: keys)
        }
    }

    private static func scan(base: UnsafePointer<UInt8>, count: Int, keys: Set<String>) -> [String: String] {
        var result: [String: String] = [:]
        var depth = 0
        var index = 0

        /// Given the index of an opening quote, returns the index just past the closing quote.
        func endOfString(from start: Int) -> Int? {
            var cursor = start + 1
            while cursor < count {
                let byte = base[cursor]
                if byte == backslash {
                    cursor += 2
                    continue
                }
                if byte == quote { return cursor + 1 }
                cursor += 1
            }
            return nil
        }

        func skipWhitespace(from start: Int) -> Int {
            var cursor = start
            while cursor < count {
                let byte = base[cursor]
                guard byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D else { break }
                cursor += 1
            }
            return cursor
        }

        /// Decodes a `"…"` token, escapes and all, by handing it to the real JSON parser.
        func decode(from start: Int, to end: Int) -> String? {
            let token = Data(bytes: base + start, count: end - start)
            return (try? JSONSerialization.jsonObject(with: token, options: [.fragmentsAllowed])) as? String
        }

        while index < count {
            switch base[index] {
            case openBrace, openBracket:
                depth += 1
                index += 1

            case closeBrace, closeBracket:
                depth -= 1
                index += 1

            case quote:
                guard let afterKey = endOfString(from: index) else { return result }
                let afterColon = skipWhitespace(from: afterKey)
                // Only a string immediately followed by ':' directly inside the root object is a
                // top-level key.
                guard depth == 1, afterColon < count, base[afterColon] == colon,
                      let key = decode(from: index, to: afterKey), keys.contains(key), result[key] == nil else {
                    index = afterKey
                    continue
                }
                let valueStart = skipWhitespace(from: afterColon + 1)
                guard valueStart < count, base[valueStart] == quote,
                      let afterValue = endOfString(from: valueStart) else {
                    // Not a string value (number, object, array, null): skip it, exactly as
                    // `HookTranslator.string` would.
                    index = afterColon + 1
                    continue
                }
                if let value = decode(from: valueStart, to: afterValue) {
                    result[key] = value
                }
                index = afterValue

            default:
                index += 1
            }
        }
        return result
    }

    /// Read a hook payload, taking the cheap path only when the expensive one would hurt.
    public static func payload(from data: Data, keys: Set<String>) -> [String: Any] {
        guard !data.isEmpty else { return [:] }
        if data.count <= fullParseLimit {
            return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        }
        return topLevelStrings(from: data, keys: keys)
    }
}
