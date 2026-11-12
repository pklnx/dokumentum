import CoreGraphics
import Foundation

// The Info dictionary of a text layer rewrite (#6, part 3, fix round 1 of PR #134, B1): PDFKit's
// `dataRepresentation()` rewrites Info values (Keywords as an array, dates in this device's time zone, booleans as
// integers), so the rewrite carries the source's Info itself. It reads every entry as CoreGraphics does, by type
// and exact value (a string's bytes, a name's bytes), writes them back as they were into an incremental update that
// replaces the Info dictionary, and the guard compares the result the same way.

extension TextLayer {
    /// One Info value as CoreGraphics reads it: its type and its exact value. Strings and names are their bytes, so
    /// a date keeps its original text and a PDFDocEncoding title its encoding.
    indirect enum InfoValue: Equatable, Sendable {
        case string([UInt8])
        case name([UInt8])
        case integer(Int)
        case real(CGFloat)
        case boolean(Bool)
        case null
        case array([InfoValue])
        case dictionary([[UInt8]: InfoValue])
    }

    /// The Info dictionary's entries by key bytes, read through CoreGraphics; empty when there is none. `nil` when an
    /// entry cannot be carried exactly (a stream, or nesting deeper than `resourceDepth`): then no rewrite.
    static func info(of document: CGPDFDocument) -> [[UInt8]: InfoValue]? {
        guard let info = document.info else { return [:] }
        return dictionaryValue(info, depth: 0)
    }

    static func dictionaryValue(_ dictionary: CGPDFDictionaryRef, depth: Int) -> [[UInt8]: InfoValue]? {
        guard depth < resourceDepth else { return nil }
        var entries: [[UInt8]: InfoValue] = [:]
        var readable = true
        CGPDFDictionaryApplyBlock(
            dictionary,
            { key, object, _ in
                guard let value = infoValue(object, depth: depth + 1) else {
                    readable = false
                    return false
                }
                entries[bytes(of: key)] = value
                return true
            }, nil)
        return readable ? entries : nil
    }

    static func infoValue(_ object: CGPDFObjectRef, depth: Int) -> InfoValue? {
        switch CGPDFObjectGetType(object) {
        case .null:
            return .null
        case .boolean:
            var value: CGPDFBoolean = 0
            guard CGPDFObjectGetValue(object, .boolean, &value) else { return nil }
            return .boolean(value != 0)
        case .integer:
            var value: CGPDFInteger = 0
            guard CGPDFObjectGetValue(object, .integer, &value) else { return nil }
            return .integer(value)
        case .real:
            var value: CGPDFReal = 0
            guard CGPDFObjectGetValue(object, .real, &value), value.isFinite else { return nil }
            return .real(value)
        case .name:
            var value: UnsafePointer<CChar>?
            guard CGPDFObjectGetValue(object, .name, &value), let value else { return nil }
            return .name(bytes(of: value))
        case .string:
            var value: CGPDFStringRef?
            guard CGPDFObjectGetValue(object, .string, &value), let value else { return nil }
            let count = CGPDFStringGetLength(value)
            guard count > 0, let start = CGPDFStringGetBytePtr(value) else { return .string([]) }
            return .string(Array(UnsafeBufferPointer(start: start, count: count)))
        case .array:
            var value: CGPDFArrayRef?
            guard depth < resourceDepth, CGPDFObjectGetValue(object, .array, &value), let value else { return nil }
            var elements: [InfoValue] = []
            for index in 0..<CGPDFArrayGetCount(value) {
                var element: CGPDFObjectRef?
                guard CGPDFArrayGetObject(value, index, &element), let element,
                    let read = infoValue(element, depth: depth + 1)
                else { return nil }
                elements.append(read)
            }
            return .array(elements)
        case .dictionary:
            var value: CGPDFDictionaryRef?
            guard CGPDFObjectGetValue(object, .dictionary, &value), let value,
                let entries = dictionaryValue(value, depth: depth)
            else { return nil }
            return .dictionary(entries)
        default:
            // A stream (or anything newer): not carried, so no rewrite.
            return nil
        }
    }

    static func bytes(of pointer: UnsafePointer<CChar>) -> [UInt8] {
        Array(UnsafeBufferPointer(start: pointer, count: strlen(pointer))).map { UInt8(bitPattern: $0) }
    }

    /// The source's Info with the marker added: what the rewrite writes and the guard expects.
    static func markedInfo(_ info: [[UInt8]: InfoValue]) -> [[UInt8]: InfoValue] {
        var marked = info
        marked[Array(markerKey.utf8)] = .string(Array("1".utf8))
        return marked
    }

    // MARK: - Writing

    /// `value` as PDF syntax that reads back as the same type and value: strings in hex (their exact bytes), names
    /// with `#xx` escapes. `nil` for a real that has no plain decimal form.
    static func serialized(_ value: InfoValue) -> String? {
        switch value {
        case .string(let bytes):
            return "<" + bytes.map { String(format: "%02X", $0) }.joined() + ">"
        case .name(let bytes):
            return serializedName(bytes)
        case .integer(let value):
            return String(value)
        case .real(let value):
            var text = String(format: "%.17f", Double(value))
            while text.hasSuffix("0") { text.removeLast() }
            if text.hasSuffix(".") { text += "0" }
            return text
        case .boolean(let value):
            return value ? "true" : "false"
        case .null:
            return "null"
        case .array(let elements):
            let parts = elements.map(serialized)
            guard !parts.contains(nil) else { return nil }
            return "[" + parts.compactMap(\.self).joined(separator: " ") + "]"
        case .dictionary(let entries):
            return serializedDictionary(entries)
        }
    }

    static func serializedDictionary(_ entries: [[UInt8]: InfoValue]) -> String? {
        var text = "<<"
        // A fixed order, so the same Info always gives the same bytes.
        for key in entries.keys.sorted(by: { $0.lexicographicallyPrecedes($1) }) {
            guard let value = entries[key].flatMap(serialized) else { return nil }
            text += " " + serializedName(key) + " " + value
        }
        return text + " >>"
    }

    /// A name: regular characters as they are, every other byte as `#xx` (ISO 32000-1, 7.3.5).
    static func serializedName(_ bytes: [UInt8]) -> String {
        let delimiters = Set("()<>[]{}/%#".utf8)
        return "/"
            + bytes.map { byte in
                (0x21...0x7E).contains(byte) && !delimiters.contains(byte)
                    ? String(UnicodeScalar(byte)) : String(format: "#%02X", byte)
            }.joined()
    }

    /// `data` with an incremental update appended whose trailer names a new Info dictionary holding `info`, written
    /// with `serialized`. The update keeps `/Root` and `/ID` of the last trailer. `nil` when `data` does not end in a
    /// classic cross-reference table and trailer (then no rewrite), or a value cannot be written.
    static func replacingInfo(in data: Data, with info: [[UInt8]: InfoValue]) -> Data? {
        guard let body = serializedDictionary(info),
            let startxref = data.range(of: Data("startxref".utf8), options: .backwards),
            let trailer = data.range(of: Data("trailer".utf8), options: .backwards, in: 0..<startxref.lowerBound),
            let trailerText = String(data: data[trailer.upperBound..<startxref.lowerBound], encoding: .isoLatin1),
            let tail = String(data: data[startxref.upperBound...], encoding: .isoLatin1),
            let previous = Int(tail.split(whereSeparator: \.isWhitespace).first ?? ""),
            previous >= 0, previous < data.count,
            data[previous...].starts(with: Data("xref".utf8)),
            let root = firstMatch(#"/Root\s+(\d+\s+\d+\s+R)"#, in: trailerText),
            let sizeText = firstMatch(#"/Size\s+(\d+)"#, in: trailerText), let size = Int(sizeText)
        else { return nil }
        var identifier = ""
        if trailerText.contains("/ID") {
            guard let id = firstMatch(#"(/ID\s*\[\s*<[0-9A-Fa-f]*>\s*<[0-9A-Fa-f]*>\s*\])"#, in: trailerText) else {
                return nil
            }
            identifier = " " + id
        }
        var update = Data("\n".utf8)
        let objectOffset = data.count + update.count
        update.append(Data("\(size) 0 obj\n\(body)\nendobj\n".utf8))
        let xrefOffset = data.count + update.count
        update.append(Data("xref\n\(size) 1\n\(String(format: "%010d", objectOffset)) 00000 n \n".utf8))
        update.append(
            Data(
                """
                trailer
                << /Size \(size + 1) /Root \(root) /Info \(size) 0 R\(identifier) /Prev \(previous) >>
                startxref
                \(xrefOffset)
                %%EOF

                """.utf8))
        return data + update
    }

    /// The first capture group of `pattern` in `text`.
    static func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let expression = try? NSRegularExpression(pattern: pattern),
            let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
            match.numberOfRanges > 1, let range = Range(match.range(at: 1), in: text)
        else { return nil }
        return String(text[range])
    }
}
