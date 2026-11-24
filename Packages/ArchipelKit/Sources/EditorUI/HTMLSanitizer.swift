import Foundation

/// Reduces the raw HTML in a Markdown file to the elements and attributes READMEs use for layout.
/// The file can come from a cloned repository nobody has read, so anything that loads, submits,
/// scripts or restyles is left out.
///
/// Nothing from the input is copied through as markup. Every tag that survives is written out again
/// from its name and its allowed attributes, and a `<` that does not start a tag is escaped, so the
/// browser cannot read the result differently from how it was read here. That also makes it safe to
/// call per fragment: swift-markdown hands inline HTML over one tag at a time, and a tag cut off by
/// the end of a fragment comes out as text, along with whatever follows it.
enum HTMLSanitizer {
    /// One fragment by itself. Tags are kept or dropped one by one, with no regard for whether
    /// they pair up; a document goes through `sanitize(_:open:)` instead.
    static func sanitize(_ html: String) -> String {
        var scanner = Scanner(bytes: Array(html.utf8), open: nil)
        return scanner.run()
    }

    /// The same, for a fragment of a larger document whose open elements are kept in `open`.
    /// A closing tag is written only when it closes one of them.
    static func sanitize(_ html: String, open: inout OpenElements) -> String {
        var scanner = Scanner(bytes: Array(html.utf8), open: open)
        let result = scanner.run()
        if let tracked = scanner.open { open = tracked }
        return result
    }

    /// The elements raw HTML has opened and not closed yet, innermost last.
    ///
    /// The browser does not let an unclosed `<a>` end with the block it is in: it opens it again
    /// in every block that follows, so one stray tag would turn the rest of the document into a
    /// link. Knowing what is open lets the renderer close such an element where its fragment ends.
    struct OpenElements {
        private var names: [String] = []
        /// How often each name is in `names`, so a closing tag that closes nothing costs no search.
        private var counts: [String: Int] = [:]

        fileprivate mutating func open(_ name: String) {
            names.append(name)
            counts[name, default: 0] += 1
        }

        func contains(_ name: String) -> Bool { counts[name, default: 0] > 0 }

        /// The closing tags for the innermost `name` and everything opened inside it, or nil when
        /// there is none. The inner ones are spelled out because the browser ignores a closing
        /// tag whose element sits behind a table cell that is still open.
        mutating func close(_ name: String) -> String? {
            guard contains(name) else { return nil }
            var tags = ""
            while let last = names.popLast() {
                counts[last, default: 1] -= 1
                tags += "</\(last)>"
                if last == name { break }
            }
            return tags
        }

        /// Closes every `name` that is still open.
        mutating func closeAll(_ name: String) -> String {
            var tags = ""
            while let closed = close(name) { tags += closed }
            return tags
        }
    }

    /// Whether a link may keep its destination. Schemes that run code in the page, or stand for
    /// content made up by the document itself, are never worth following. Any other scheme stays:
    /// the app decides what happens on a click.
    /// `decodingEntities` is for values taken from raw HTML, where the browser decodes them first.
    static func isSafeLinkDestination(_ value: String, decodingEntities: Bool = false) -> Bool {
        switch destination(of: value, decodingEntities: decodingEntities) {
        case .relative: true
        case .scheme(let scheme): !scriptSchemes.contains(scheme)
        case .unclear: false
        }
    }

    static let scriptSchemes: Set<String> = ["javascript", "vbscript", "data", "blob"]

    /// Mirrors the `img-src` of the preview's Content Security Policy, so an image that would be
    /// blocked does not leave a request behind in the markup.
    static func isSafeImageSource(_ value: String, decodingEntities: Bool = false) -> Bool {
        isSafeImageSource(urlScalars(value, decodingEntities: decodingEntities))
    }

    private static func isSafeImageSource(_ url: [URLScalar]) -> Bool {
        switch destination(of: url) {
        case .relative: true
        case .scheme("https"): true
        case .scheme("data"): text(url).lowercased().hasPrefix("data:image/")
        case .scheme, .unclear: false
        }
    }

    enum Destination: Equatable {
        case relative
        case scheme(String)
        /// Could not be told apart from a URL with a hidden scheme.
        case unclear
    }

    static func destination(of value: String, decodingEntities: Bool = false) -> Destination {
        destination(of: urlScalars(value, decodingEntities: decodingEntities))
    }

    private static func destination(of url: [URLScalar]) -> Destination {
        // A scheme has to come before the first slash, question mark or hash.
        let head = url.prefix { $0.scalar != "/" && $0.scalar != "?" && $0.scalar != "#" }
        // An entity that was not decoded here could still become a colon or a tab in the browser.
        // An ampersand that came out of `&amp;` cannot: the browser decodes only once.
        if head.contains(where: \.isUndecodedAmpersand) { return .unclear }
        guard let colon = head.firstIndex(where: { $0.scalar == ":" }) else { return .relative }
        let scheme = head[..<colon].map(\.scalar)
        guard let first = scheme.first, isASCIILetter(first),
              scheme.allSatisfy({ isASCIILetter($0) || ("0"..."9").contains($0) || $0 == "+" || $0 == "-" || $0 == "." })
        else { return .unclear }
        return .scheme(text(scheme).lowercased())
    }

    /// One character of a URL, remembering whether it is an `&` the decoder could not make
    /// sense of.
    private struct URLScalar {
        var scalar: Unicode.Scalar
        var isUndecodedAmpersand = false
    }

    private static func urlScalars(_ value: String, decodingEntities: Bool) -> [URLScalar] {
        cleaned(decodingEntities ? decode(value) : value.unicodeScalars.map { URLScalar(scalar: $0) })
    }

    /// The value as a browser's URL parser sees it: the whitespace and control characters around
    /// it gone, and tabs and newlines gone from anywhere, since `java\tscript:` is still
    /// `javascript:` to the parser.
    private static func cleaned(_ url: [URLScalar]) -> [URLScalar] {
        var scalars = url.filter { $0.scalar != "\t" && $0.scalar != "\n" && $0.scalar != "\r" }
        let leading = scalars.prefix { $0.scalar.value <= 0x20 }.count
        scalars.removeFirst(leading)
        while let last = scalars.last, last.scalar.value <= 0x20 { scalars.removeLast() }
        return scalars
    }

    private static func text(_ url: [URLScalar]) -> String { text(url.map(\.scalar)) }

    private static func text(_ scalars: some Sequence<Unicode.Scalar>) -> String {
        var view = String.UnicodeScalarView()
        view.append(contentsOf: scalars)
        return String(view)
    }

    private static func isASCIILetter(_ scalar: Unicode.Scalar) -> Bool {
        ("a"..."z").contains(scalar) || ("A"..."Z").contains(scalar)
    }

    /// The whitespace HTML splits attribute values on.
    private static func isHTMLWhitespace(_ scalar: Unicode.Scalar) -> Bool {
        scalar == " " || scalar == "\t" || scalar == "\n" || scalar == "\u{0C}" || scalar == "\r"
    }

    private static let namedEntities: [String: Unicode.Scalar] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "colon": ":", "Tab": "\t", "NewLine": "\n",
        // Splits a srcset into candidates just like a literal comma.
        "comma": ",",
    ]

    /// Numeric references, with or without the semicolon, and the few named ones that matter for
    /// spotting a scheme. Whatever is left undecoded keeps its `&`, which `destination` distrusts.
    static func decodeEntities(_ text: String) -> String {
        self.text(decode(text))
    }

    private static func decode(_ text: String) -> [URLScalar] {
        let scalars = Array(text.unicodeScalars)
        var result: [URLScalar] = []
        result.reserveCapacity(scalars.count)
        var index = 0
        while index < scalars.count {
            guard scalars[index] == "&" else {
                result.append(URLScalar(scalar: scalars[index]))
                index += 1
                continue
            }
            var end = index + 1
            var decoded: Unicode.Scalar?
            if end < scalars.count, scalars[end] == "#" {
                end += 1
                var radix = 10
                if end < scalars.count, scalars[end] == "x" || scalars[end] == "X" {
                    radix = 16
                    end += 1
                }
                let start = end
                while end < scalars.count, Character(scalars[end]).isHexDigit, radix == 16 || Character(scalars[end]).isNumber { end += 1 }
                if end > start, end - start <= 8, let value = UInt32(self.text(scalars[start..<end]), radix: radix) {
                    // The browser turns a reference it cannot represent into U+FFFD rather than dropping it.
                    decoded = Unicode.Scalar(value).flatMap { $0.value == 0 ? nil : $0 } ?? "\u{FFFD}"
                    if end < scalars.count, scalars[end] == ";" { end += 1 }
                }
            } else {
                let start = end
                while end < scalars.count, end - start < 8, isASCIILetter(scalars[end]) { end += 1 }
                if end < scalars.count, scalars[end] == ";",
                   let scalar = namedEntities[self.text(scalars[start..<end])] {
                    decoded = scalar
                    end += 1
                }
            }
            if let decoded {
                result.append(URLScalar(scalar: decoded))
                index = end
            } else {
                result.append(URLScalar(scalar: "&", isUndecodedAmpersand: true))
                index += 1
            }
        }
        return result
    }

    // MARK: Allowlist

    /// What GitHub keeps as well, minus everything that is parsed in a mode of its own (`style`,
    /// `textarea`, `svg`, ...), since the scanner below only knows ordinary elements.
    static let allowedElements: Set<String> = [
        "a", "abbr", "b", "bdo", "blockquote", "br", "caption", "center", "cite", "code", "col", "colgroup",
        "dd", "del", "details", "dfn", "div", "dl", "dt", "em", "figcaption", "figure", "font",
        "h1", "h2", "h3", "h4", "h5", "h6", "hr", "i", "img", "ins", "kbd", "li", "mark", "ol", "p", "picture",
        "pre", "q", "rp", "rt", "ruby", "s", "samp", "small", "source", "span", "strike", "strong", "sub",
        "summary", "sup", "table", "tbody", "td", "tfoot", "th", "thead", "tr", "tt", "u", "ul", "var", "wbr",
    ]

    private static let voidElements: Set<String> = ["br", "col", "hr", "img", "source", "wbr"]

    /// Their content is not prose, so it goes with the tag instead of showing up as text.
    private static let elementsDroppedWithContent: Set<String> = [
        "script", "style", "title", "textarea", "iframe", "object", "noscript", "noembed", "noframes",
        "xmp", "template", "svg", "math", "select",
    ]

    /// No `class` and no `style`: both let the document borrow or bring its own styling.
    private static let globalAttributes: Set<String> = [
        "align", "dir", "height", "id", "lang", "title", "valign", "width",
    ]

    private static let elementAttributes: [String: Set<String>] = [
        "a": ["href", "name"],
        "img": ["src", "srcset", "sizes", "alt", "border"],
        "source": ["srcset", "sizes", "media", "type"],
        "details": ["open"],
        "ol": ["start", "type", "reversed"],
        "ul": ["type"],
        "li": ["value"],
        "table": ["border", "cellpadding", "cellspacing", "summary"],
        "td": ["colspan", "rowspan", "headers", "abbr", "scope"],
        "th": ["colspan", "rowspan", "headers", "abbr", "scope"],
        "col": ["span"],
        "colgroup": ["span"],
        "font": ["color", "face", "size"],
        "hr": ["size", "noshade"],
        "br": ["clear"],
        "del": ["datetime"],
        "ins": ["datetime"],
    ]

    enum AttributeVerdict: Equatable {
        case drop
        /// As written.
        case keep
        case rewrite(String)
    }

    fileprivate static func verdict(attribute: String, value: String?, on element: String) -> AttributeVerdict {
        guard globalAttributes.contains(attribute) || elementAttributes[element]?.contains(attribute) == true else { return .drop }
        switch attribute {
        case "href":
            return isSafeLinkDestination(value ?? "", decodingEntities: true) ? .keep : .drop
        case "src":
            return isSafeImageSource(value ?? "", decodingEntities: true) ? .keep : .drop
        case "srcset":
            return isSafeSourceSet(value ?? "") ? .keep : .drop
        case "width", "height":
            return cappedLength(value ?? "", limit: maximumDimension).map(AttributeVerdict.rewrite) ?? .drop
        case "border", "cellpadding", "cellspacing":
            return cappedLength(value ?? "", limit: maximumSpacing).map(AttributeVerdict.rewrite) ?? .drop
        case "size" where element == "hr":
            return cappedLength(value ?? "", limit: maximumSpacing).map(AttributeVerdict.rewrite) ?? .drop
        default:
            return .keep
        }
    }

    /// Each candidate is a URL followed by a size, and every one of them has to pass. The browser
    /// splits the value after decoding it, so an encoded comma separates candidates too. It also
    /// lets a URL contain commas; splitting there as well only judges more pieces than there are.
    static func isSafeSourceSet(_ value: String) -> Bool {
        decode(value).split(whereSeparator: { $0.scalar == "," }).allSatisfy { candidate in
            let url = candidate.drop { isHTMLWhitespace($0.scalar) }.prefix { !isHTMLWhitespace($0.scalar) }
            return url.isEmpty || isSafeImageSource(cleaned(Array(url)))
        }
    }

    /// Larger than any screen, small enough that an element cannot push the rest of the document
    /// out of reach or lay a link over whole pages of it.
    static let maximumDimension = 2000
    /// For borders, cell padding and rule thickness.
    static let maximumSpacing = 100

    /// A length or percentage the way HTML reads one: leading digits count, what follows them
    /// does not. Written out again as just the number, held to `limit`. Nil without digits.
    static func cappedLength(_ value: String, limit: Int) -> String? {
        var scalars = decode(value).map(\.scalar).drop(while: isHTMLWhitespace)
        var number = 0
        var digits = 0
        while let digit = scalars.first, ("0"..."9").contains(digit) {
            // Held to the limit as it grows, so no run of digits can overflow.
            number = min(number * 10 + Int(digit.value - 48), limit)
            digits += 1
            scalars.removeFirst()
        }
        guard digits > 0 else { return nil }
        if scalars.first == "." {
            scalars.removeFirst()
            scalars = scalars.drop { ("0"..."9").contains($0) }
        }
        return scalars.first == "%" ? "\(min(number, 100))%" : "\(number)"
    }

    fileprivate static func isVoid(_ element: String) -> Bool { voidElements.contains(element) }
    fileprivate static func dropsContent(of element: String) -> Bool { elementsDroppedWithContent.contains(element) }
}

private struct Scanner {
    let bytes: [UInt8]
    /// Nil when the fragment stands alone and closing tags are taken as they come.
    private(set) var open: HTMLSanitizer.OpenElements?
    private var position = 0
    private var output: [UInt8] = []

    init(bytes: [UInt8], open: HTMLSanitizer.OpenElements?) {
        self.bytes = bytes
        self.open = open
    }

    private enum Markup {
        case consumed
        /// The `<` starts nothing. Nothing was consumed.
        case text
        /// A tag began and the fragment ended before it did. Nothing was consumed.
        case cutOff
    }

    mutating func run() -> String {
        output.reserveCapacity(bytes.count)
        while position < bytes.count {
            if bytes[position] != UInt8(ascii: "<") {
                output.append(bytes[position])
                position += 1
                continue
            }
            switch consumeMarkup() {
            case .consumed:
                break
            case .text:
                appendEscaped(bytes[position])
                position += 1
            case .cutOff:
                // Finding that out took a scan to the end of the fragment. Looking for tags
                // again from the next `<` would repeat that scan for each one, which is
                // quadratic on input made of nothing but tag openings. The browser drops a tag
                // like this together with everything after it; here it all shows as text.
                for byte in bytes[position...] { appendEscaped(byte) }
                position = bytes.count
            }
        }
        return String(decoding: output, as: UTF8.self)
    }

    private mutating func appendEscaped(_ byte: UInt8) {
        if byte == UInt8(ascii: "<") {
            output += Array("&lt;".utf8)
        } else {
            output.append(byte)
        }
    }

    /// At a `<`.
    private mutating func consumeMarkup() -> Markup {
        guard position + 1 < bytes.count else { return .text }
        let next = bytes[position + 1]
        if next == UInt8(ascii: "!") {
            if starts(with: "<!--", at: position) {
                // Searching from the second character on also ends `<!-->`, as the browser would.
                // An unclosed comment swallows the rest: CommonMark ends that block at `-->` too.
                position = index(after: "-->", from: position + 2) ?? bytes.count
            } else {
                position = index(after: ">", from: position) ?? bytes.count
            }
            return .consumed
        }
        if next == UInt8(ascii: "?") {
            position = index(after: ">", from: position) ?? bytes.count
            return .consumed
        }
        if next == UInt8(ascii: "/") {
            guard position + 2 < bytes.count, Self.isLetter(bytes[position + 2]) else { return .text }
            guard let end = index(after: ">", from: position) else { return .cutOff }
            let name = tagName(from: position + 2).name
            position = end
            if HTMLSanitizer.allowedElements.contains(name), !HTMLSanitizer.isVoid(name) {
                if open != nil {
                    // One that closes nothing would end an element the renderer wrote itself.
                    output += Array((open?.close(name) ?? "").utf8)
                } else {
                    output += Array("</\(name)>".utf8)
                }
            }
            return .consumed
        }
        guard Self.isLetter(next) else { return .text }
        return consumeOpeningTag()
    }

    private mutating func consumeOpeningTag() -> Markup {
        let (name, nameEnd) = tagName(from: position + 1)
        var index = nameEnd
        var attributes: [(name: String, value: String?)] = []
        while true {
            while index < bytes.count, Self.isWhitespace(bytes[index]) || bytes[index] == UInt8(ascii: "/") { index += 1 }
            // The fragment ended inside the tag, so there is no tag.
            guard index < bytes.count else { return .cutOff }
            if bytes[index] == UInt8(ascii: ">") {
                index += 1
                break
            }
            let nameStart = index
            // HTML lets a name begin with `=`. Taking it along keeps the loop moving.
            index += 1
            while index < bytes.count, !Self.isWhitespace(bytes[index]), !">/=".utf8.contains(bytes[index]) { index += 1 }
            let attribute = String(decoding: bytes[nameStart..<index], as: UTF8.self).lowercased()
            var value: String?
            var afterName = index
            while afterName < bytes.count, Self.isWhitespace(bytes[afterName]) { afterName += 1 }
            if afterName < bytes.count, bytes[afterName] == UInt8(ascii: "=") {
                index = afterName + 1
                while index < bytes.count, Self.isWhitespace(bytes[index]) { index += 1 }
                guard index < bytes.count else { return .cutOff }
                let quote = bytes[index]
                if quote == UInt8(ascii: "\"") || quote == UInt8(ascii: "'") {
                    guard let close = bytes[(index + 1)...].firstIndex(of: quote) else { return .cutOff }
                    value = String(decoding: bytes[(index + 1)..<close], as: UTF8.self)
                    index = close + 1
                } else {
                    let start = index
                    while index < bytes.count, !Self.isWhitespace(bytes[index]), bytes[index] != UInt8(ascii: ">") { index += 1 }
                    value = String(decoding: bytes[start..<index], as: UTF8.self)
                }
            }
            attributes.append((attribute, value))
        }
        position = index

        if HTMLSanitizer.dropsContent(of: name) {
            position = self.index(afterClosingTag: name, from: position) ?? bytes.count
            return .consumed
        }
        guard HTMLSanitizer.allowedElements.contains(name) else { return .consumed }

        var tag = "<\(name)"
        var seen: Set<String> = []
        // The browser keeps the first of a repeated attribute, so that is the one to judge.
        for (attribute, value) in attributes where seen.insert(attribute).inserted {
            switch HTMLSanitizer.verdict(attribute: attribute, value: value, on: name) {
            case .drop:
                continue
            case .keep:
                tag += " \(attribute)"
                if let value { tag += "=\"\(Self.escapeAttribute(value))\"" }
            case .rewrite(let replacement):
                tag += " \(attribute)=\"\(Self.escapeAttribute(replacement))\""
            }
        }
        output += Array("\(tag)>".utf8)
        if !HTMLSanitizer.isVoid(name) { open?.open(name) }
        return .consumed
    }

    /// Lowercased, up to the first character that ends a tag name. A name with anything unusual
    /// in it comes back as it is and matches nothing in the allowlist.
    private func tagName(from start: Int) -> (name: String, end: Int) {
        var end = start
        while end < bytes.count, !Self.isWhitespace(bytes[end]), bytes[end] != UInt8(ascii: "/"), bytes[end] != UInt8(ascii: ">") { end += 1 }
        return (String(decoding: bytes[start..<end], as: UTF8.self).lowercased(), end)
    }

    /// `&` stays as written so entities in the value keep their meaning; inside the quotes this
    /// writes, only a quote could end the value.
    private static func escapeAttribute(_ value: String) -> String {
        var result = ""
        for character in value {
            switch character {
            case "\"": result += "&quot;"
            case "<": result += "&lt;"
            case ">": result += "&gt;"
            default: result.append(character)
            }
        }
        return result
    }

    private func starts(with text: String, at start: Int) -> Bool {
        let needle = Array(text.utf8)
        return start + needle.count <= bytes.count && bytes[start..<(start + needle.count)].elementsEqual(needle)
    }

    /// The position just past the next `text`.
    private func index(after text: String, from start: Int) -> Int? {
        let needle = Array(text.utf8)
        guard start <= bytes.count, bytes.count - start >= needle.count else { return nil }
        for candidate in start...(bytes.count - needle.count) where bytes[candidate..<(candidate + needle.count)].elementsEqual(needle) {
            return candidate + needle.count
        }
        return nil
    }

    /// The position just past `</name ...>`, whatever its case.
    private func index(afterClosingTag name: String, from start: Int) -> Int? {
        let needle = Array("</\(name)".utf8)
        guard start <= bytes.count, bytes.count - start >= needle.count else { return nil }
        for candidate in start...(bytes.count - needle.count) {
            let end = candidate + needle.count
            guard bytes[candidate..<end].lazy.map(Self.lowercased).elementsEqual(needle) else { continue }
            // `</scripted>` does not close a script.
            if end < bytes.count, !Self.isWhitespace(bytes[end]), bytes[end] != UInt8(ascii: "/"), bytes[end] != UInt8(ascii: ">") { continue }
            return index(after: ">", from: end) ?? bytes.count
        }
        return nil
    }

    private static func lowercased(_ byte: UInt8) -> UInt8 {
        (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte) ? byte + 32 : byte
    }

    private static func isLetter(_ byte: UInt8) -> Bool {
        (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(lowercased(byte))
    }

    private static func isWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0C || byte == 0x0D
    }
}
