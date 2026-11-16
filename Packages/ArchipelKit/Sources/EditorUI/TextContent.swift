import Foundation

enum TextSniffer {
    /// The same test git uses: a NUL byte near the start means binary.
    static let sniffLength = 8_000

    static func isBinary(_ data: Data) -> Bool {
        if unicodeBOM(data) != nil { return false }
        return data.prefix(sniffLength).contains(0)
    }

    /// Decodes text the way an editor would guess it: BOM first, then strict UTF-8, then Latin-1 so
    /// that a stray legacy byte still shows the file instead of refusing it. Nil means binary.
    static func decode(_ data: Data) -> String? {
        decodeWithFormat(data)?.text
    }

    /// Like `decode`, but also reports how to write the text back so a save changes nothing else:
    /// the encoding, the BOM, and a uniform CRLF or CR convention (folded to LF while editing).
    static func decodeWithFormat(_ data: Data) -> (text: String, format: TextFileFormat)? {
        var format = TextFileFormat()
        let decoded: String?
        if let (encoding, bomLength) = unicodeBOM(data) {
            format.encoding = encoding
            format.hasBOM = true
            decoded = String(data: data.dropFirst(bomLength), encoding: encoding)
        } else if isBinary(data) {
            return nil
        } else if let text = String(data: data, encoding: .utf8) {
            decoded = text
        } else if let text = String(data: data, encoding: .windowsCP1252) {
            format.encoding = .windowsCP1252
            decoded = text
        } else {
            format.encoding = .isoLatin1
            decoded = String(data: data, encoding: .isoLatin1)
        }
        guard var text = decoded else { return nil }
        format.lineEnding = TextFileFormat.LineEnding.detect(in: text)
        switch format.lineEnding {
        case .crlf: text = text.replacingOccurrences(of: "\r\n", with: "\n")
        case .cr: text = text.replacingOccurrences(of: "\r", with: "\n")
        case .lf: break
        }
        return (text, format)
    }

    private static func unicodeBOM(_ data: Data) -> (String.Encoding, Int)? {
        let bytes = Array(data.prefix(3))
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { return (.utf8, 3) }
        if bytes.starts(with: [0xFF, 0xFE]) { return (.utf16LittleEndian, 2) }
        if bytes.starts(with: [0xFE, 0xFF]) { return (.utf16BigEndian, 2) }
        return nil
    }
}

/// How a text file is stored on disk, kept so a save writes it back the same way.
struct TextFileFormat: Equatable, Sendable {
    enum LineEnding: Equatable, Sendable {
        /// LF, or a mix that is left exactly as it is.
        case lf
        case crlf
        case cr

        /// Only a file that uses one convention throughout is folded to LF; a mixed file is kept
        /// verbatim, since rewriting every line would turn a one-word edit into a whole-file diff.
        static func detect(in text: String) -> LineEnding {
            var crlf = 0
            var lf = 0
            var cr = 0
            var previousWasCR = false
            for unit in text.utf8 {
                if unit == 0x0A {
                    if previousWasCR { crlf += 1; cr -= 1 } else { lf += 1 }
                } else if unit == 0x0D {
                    cr += 1
                }
                previousWasCR = unit == 0x0D
            }
            if crlf > 0, lf == 0, cr == 0 { return .crlf }
            if cr > 0, lf == 0, crlf == 0 { return .cr }
            return .lf
        }
    }

    var encoding: String.Encoding = .utf8
    var hasBOM = false
    var lineEnding = LineEnding.lf

    struct EncodingError: LocalizedError {
        var encoding: String.Encoding
        var errorDescription: String? {
            String(localized: "The text contains characters that can't be saved in \(String.localizedName(of: encoding)).")
        }
    }

    func encode(_ text: String) throws -> Data {
        var text = text
        switch lineEnding {
        case .crlf:
            // Pasted text can bring its own CRLFs; fold them first so they don't become CR CR LF.
            text = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\n", with: "\r\n")
        case .cr:
            text = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\n", with: "\r")
        case .lf:
            break
        }
        guard var data = text.data(using: encoding, allowLossyConversion: false) else { throw EncodingError(encoding: encoding) }
        // Foundation adds its own BOM for UTF-16, so strip it and decide here.
        if encoding == .utf16LittleEndian || encoding == .utf16BigEndian {
            if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) { data = data.dropFirst(2) }
        }
        guard hasBOM else { return data }
        let bom: [UInt8] = switch encoding {
        case .utf16LittleEndian: [0xFF, 0xFE]
        case .utf16BigEndian: [0xFE, 0xFF]
        default: [0xEF, 0xBB, 0xBF]
        }
        return Data(bom) + data
    }
}

/// What the Tab key inserts, guessed from how the file is already indented.
enum IndentationStyle: Equatable, Sendable {
    case tab
    case spaces(Int)

    var text: String {
        switch self {
        case .tab: "\t"
        case .spaces(let count): String(repeating: " ", count: count)
        }
    }

    /// Looks at the first few hundred indented lines: tabs win if most start with one, otherwise the
    /// smallest common step between space indents. Unknown files get a literal tab.
    static func detect(in text: String) -> IndentationStyle {
        var tabs = 0
        var spaceLines = 0
        var widths: [Int: Int] = [:]
        var previous = 0
        var examined = 0
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard examined < 500 else { break }
            guard let first = line.first, first == " " || first == "\t" else {
                previous = 0
                continue
            }
            examined += 1
            if first == "\t" {
                tabs += 1
                continue
            }
            let count = line.prefix { $0 == " " }.count
            guard line.dropFirst(count).first.map({ !$0.isWhitespace }) ?? false else { continue }
            spaceLines += 1
            let step = abs(count - previous)
            if step > 0 { widths[step, default: 0] += 1 }
            previous = count
        }
        if tabs == 0, spaceLines == 0 { return .tab }
        if tabs >= spaceLines { return .tab }
        let width = widths.max { $0.value == $1.value ? $0.key > $1.key : $0.value < $1.value }?.key ?? 4
        return .spaces([2, 3, 4, 8].contains(width) ? width : 4)
    }
}

/// UTF-16 offsets of every line start, matching how NSString and TextKit break paragraphs
/// (LF, CR, CRLF, NEL, U+2028 and U+2029), so line numbers line up with what TextKit lays out.
struct LineIndex: Equatable, Sendable {
    private(set) var starts: [Int]
    private(set) var length: Int

    /// Reads UTF-16 straight from the NSString. The editor passes NSTextStorage's bridged string, where
    /// the UTF-8 view has no contiguous storage and would copy and transcode the whole file per keystroke.
    init(_ text: String) {
        let string = text as NSString
        let length = string.length
        var starts = [0]
        var afterCR = false
        let chunk = 4096
        withUnsafeTemporaryAllocation(of: unichar.self, capacity: chunk) { units in
            var location = 0
            while location < length {
                let count = min(chunk, length - location)
                string.getCharacters(units.baseAddress!, range: NSRange(location: location, length: count))
                for index in 0..<count {
                    let unit = units[index]
                    let offset = location + index
                    // CRLF is one break: move the start the CR recorded past the LF. Tracked across
                    // chunks, since the pair can straddle a boundary.
                    if afterCR {
                        afterCR = false
                        if unit == 0x0A {
                            starts[starts.count - 1] = offset + 1
                            continue
                        }
                    }
                    switch unit {
                    case 0x0A, 0x85, 0x2028, 0x2029:
                        starts.append(offset + 1)
                    case 0x0D:
                        starts.append(offset + 1)
                        afterCR = true
                    default:
                        break
                    }
                }
                location += count
            }
        }
        self.starts = starts
        self.length = length
    }

    var lineCount: Int { starts.count }

    /// Zero-based line that contains the UTF-16 offset.
    func line(containing offset: Int) -> Int {
        var low = 0
        var high = starts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if starts[mid] <= offset { low = mid } else { high = mid - 1 }
        }
        return low
    }
}
