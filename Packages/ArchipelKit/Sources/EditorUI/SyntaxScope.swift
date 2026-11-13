import Foundation

/// The colour roles of Xcode's default theme, which highlight.js scopes are folded into.
enum SyntaxScope: UInt8, Sendable {
    case plain, keyword, string, comment, number, typeName, typeDeclaration, declaration, functionCall
    case preprocessor, attribute, url, variable, addition, deletion

    /// Maps a highlight.js class attribute such as `hljs-title function_ invoke__`.
    /// Nil means the span carries no colour of its own and inherits its parent's.
    init?(highlightClass: some StringProtocol) {
        let parts = highlightClass.split(separator: " ")
        guard let first = parts.first, first.hasPrefix("hljs-") else { return nil }
        let modifiers = parts.dropFirst()
        switch first.dropFirst(5) {
        case "keyword", "literal", "selector-tag", "name", "bullet", "template-tag":
            self = .keyword
        case "variable" where modifiers.contains("language_"):
            self = .keyword
        case "variable", "template-variable":
            self = .variable
        case "built_in", "type":
            self = .typeName
        case "title" where modifiers.contains("invoke__"):
            self = .functionCall
        case "title" where modifiers.contains("inherited__"):
            self = .typeName
        case "title" where modifiers.contains("class_"), "class", "section":
            self = .typeDeclaration
        case "title", "attr", "selector-id", "selector-class":
            self = .declaration
        case "string", "char", "code", "regexp":
            self = .string
        case "comment", "quote", "doctag":
            self = .comment
        case "number", "symbol":
            self = .number
        case "meta":
            self = .preprocessor
        case "attribute", "selector-attr", "selector-pseudo":
            self = .attribute
        case "link":
            self = .url
        case "addition":
            self = .addition
        case "deletion":
            self = .deletion
        case "subst", "params", "property", "operator", "punctuation", "tag":
            self = .plain
        default:
            return nil
        }
    }
}

struct HighlightRun: Equatable, Sendable {
    /// UTF-16 offset and length, so a run maps straight onto an NSRange.
    var location: Int
    var length: Int
    var scope: SyntaxScope

    var range: NSRange { NSRange(location: location, length: length) }
}

/// Turns the HTML that `hljs.highlight` returns into coloured runs over the original text.
///
/// highlight.js only ever emits `<span class="...">`, `</span>` and five escaped characters, so a
/// byte scanner is enough and avoids NSAttributedString's HTML importer, which needs the main thread.
enum HighlightHTMLParser {
    /// Returns the runs (plain text omitted) and the UTF-16 length of the decoded text.
    static func runs(fromHTML html: String) -> (runs: [HighlightRun], length: Int) {
        var html = html
        return html.withUTF8 { parse($0) }
    }

    private static func parse(_ bytes: UnsafeBufferPointer<UInt8>) -> (runs: [HighlightRun], length: Int) {
        var runs: [HighlightRun] = []
        var stack: [SyntaxScope?] = []
        var effective = SyntaxScope.plain
        var offset = 0
        var runStart = 0
        var index = 0
        let count = bytes.count

        func setEffective(_ scope: SyntaxScope) {
            guard scope != effective else { return }
            if effective != .plain, offset > runStart {
                if let last = runs.last, last.scope == effective, last.location + last.length == runStart {
                    runs[runs.count - 1].length += offset - runStart
                } else {
                    runs.append(HighlightRun(location: runStart, length: offset - runStart, scope: effective))
                }
            }
            effective = scope
            runStart = offset
        }

        func recompute() {
            setEffective(stack.last(where: { $0 != nil }).flatMap(\.self) ?? .plain)
        }

        while index < count {
            let byte = bytes[index]
            if byte == UInt8(ascii: "<") {
                guard let close = find(UInt8(ascii: ">"), in: bytes, from: index) else { break }
                if index + 1 < count, bytes[index + 1] == UInt8(ascii: "/") {
                    if !stack.isEmpty { stack.removeLast() }
                } else {
                    stack.append(classAttribute(bytes, from: index, to: close).flatMap { SyntaxScope(highlightClass: $0) })
                }
                recompute()
                index = close + 1
                continue
            }
            if byte == UInt8(ascii: "&"), let semicolon = find(UInt8(ascii: ";"), in: bytes, from: index, limit: 12) {
                let entity = String(decoding: UnsafeBufferPointer(rebasing: bytes[(index + 1)..<semicolon]), as: UTF8.self)
                offset += entityLength(entity)
                index = semicolon + 1
                continue
            }
            switch byte {
            case 0xF0...0xFF: offset += 2
            case 0x80...0xBF: break
            default: offset += 1
            }
            index += 1
        }
        setEffective(.plain)
        return (runs, offset)
    }

    private static func find(_ target: UInt8, in bytes: UnsafeBufferPointer<UInt8>, from start: Int, limit: Int = .max) -> Int? {
        var index = start
        let end = limit == .max ? bytes.count : min(bytes.count, start + limit)
        while index < end {
            if bytes[index] == target { return index }
            index += 1
        }
        return nil
    }

    private static func classAttribute(_ bytes: UnsafeBufferPointer<UInt8>, from start: Int, to end: Int) -> String? {
        let tag = String(decoding: UnsafeBufferPointer(rebasing: bytes[start..<end]), as: UTF8.self)
        guard let open = tag.range(of: "class=\"") else { return nil }
        let rest = tag[open.upperBound...]
        return String(rest.prefix { $0 != "\"" })
    }

    /// UTF-16 length of what an entity stands for: one unit, or two for an astral numeric reference.
    private static func entityLength(_ entity: String) -> Int {
        guard entity.hasPrefix("#") else { return 1 }
        let digits = entity.dropFirst()
        let value = digits.first == "x" || digits.first == "X" ? Int(digits.dropFirst(), radix: 16) : Int(digits)
        return (value ?? 0) > 0xFFFF ? 2 : 1
    }
}
