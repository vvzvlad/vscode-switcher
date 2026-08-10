import Foundation

/// Tolerant JSON reader for the JSON-with-comments dialect VSCode uses in
/// `*.code-workspace` and `.vscode/settings.json`.
///
/// `JSONSerialization` rejects both comments and trailing commas, so the text is
/// normalised first. The scan runs over UTF-8 bytes: every syntactic character
/// is ASCII and multi-byte sequences never contain ASCII bytes, so byte-level
/// scanning is safe for any input encoding-wise.
///
/// The one thing that must not break is string literals — a `//` inside a value
/// such as `"https://example.com"` is data, not a comment.
enum JSONC {
    /// Removes `//` and `/* */` comments and commas dangling before `}` or `]`.
    static func stripped(_ text: String) -> String {
        let bytes = Array(text.utf8)
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count)

        let quote: UInt8 = 0x22
        let backslash: UInt8 = 0x5C
        let slash: UInt8 = 0x2F
        let star: UInt8 = 0x2A
        let comma: UInt8 = 0x2C
        let closeBrace: UInt8 = 0x7D
        let closeBracket: UInt8 = 0x5D

        var index = 0
        var inString = false

        while index < bytes.count {
            let byte = bytes[index]

            if inString {
                out.append(byte)
                if byte == backslash, index + 1 < bytes.count {
                    // Copy the escaped byte verbatim so \" does not end the string.
                    out.append(bytes[index + 1])
                    index += 2
                    continue
                }
                if byte == quote { inString = false }
                index += 1
                continue
            }

            if byte == quote {
                inString = true
                out.append(byte)
                index += 1
                continue
            }

            if byte == slash, index + 1 < bytes.count {
                let next = bytes[index + 1]
                if next == slash {
                    index += 2
                    while index < bytes.count, bytes[index] != 0x0A, bytes[index] != 0x0D {
                        index += 1
                    }
                    continue
                }
                if next == star {
                    index += 2
                    while index + 1 < bytes.count, !(bytes[index] == star && bytes[index + 1] == slash) {
                        index += 1
                    }
                    index = min(index + 2, bytes.count)
                    continue
                }
            }

            if byte == closeBrace || byte == closeBracket {
                // Walk back over whitespace only; the first non-space byte is
                // either the dangling comma or something that must stay, so a
                // comma inside a string can never be reached from here.
                var back = out.count - 1
                while back >= 0, isWhitespace(out[back]) { back -= 1 }
                if back >= 0, out[back] == comma { out.remove(at: back) }
            }

            out.append(byte)
            index += 1
        }

        return String(decoding: out, as: UTF8.self)
    }

    private static func isWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D
    }

    /// Parses JSONC text into the usual `JSONSerialization` value tree.
    static func parse(_ text: String) throws -> Any {
        let cleaned = stripped(text)
        let data = Data(cleaned.utf8)
        return try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }

    /// Reads a JSONC file as a dictionary. Any failure — missing file, unreadable
    /// bytes, broken syntax, wrong root type — yields `nil`; on-disk files can
    /// legitimately be mid-write or hand-broken and must never abort a refresh.
    static func object(atPath path: String) -> [String: Any]? {
        guard let data = FileManager.default.contents(atPath: path),
              let text = String(data: data, encoding: .utf8),
              let value = try? parse(text)
        else {
            return nil
        }
        return value as? [String: Any]
    }
}
