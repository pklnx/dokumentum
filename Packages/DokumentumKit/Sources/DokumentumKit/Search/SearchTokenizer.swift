import Foundation

/// One word of a query: the document must have a word that starts with one of `forms`, or, when the word typed
/// has `SearchIndex.infixMinimumLength` or more characters, contains one of them (plan of #7, Approach 4).
public struct SearchTerm: Sendable, Hashable {
    /// The normalised word first, then its alternatives: the *a/o/u* form of *ae/oe/ue*, and the transcription of
    /// a word typed with ä, ö or ü.
    public let forms: [String]
    /// Whether the forms also match inside a word. Decided once per term by the length of what was typed, so
    /// every alternative follows the same rule: "Mül" (3) does not infix-match through its 4-letter
    /// transcription `muel` (review of #125, N2).
    public let allowsInfix: Bool

    /// - Parameter typedLength: the characters of the word as typed; by default those of the first form.
    public init(forms: [String], typedLength: Int? = nil) {
        var unique: [String] = []
        for form in forms where !form.isEmpty && !unique.contains(form) { unique.append(form) }
        self.forms = unique
        allowsInfix = (typedLength ?? unique.first?.count ?? 0) >= SearchIndex.infixMinimumLength
    }
}

/// Splits texts and queries into normalised words (plan of #7, Approach 5).
///
/// A word is a maximal run of letters, digits and combining marks; everything else separates it (space,
/// punctuation, hyphen, U+2011, slash, apostrophe, the form feed between pages). Numbers split at their
/// punctuation: "12.03.2024" is `12`, `03`, `2024`. A hyphen at the end of a line followed by a lowercase letter
/// joins the two parts ("Steuer-\nbescheid" is `steuerbescheid`); before anything else it separates ("Kfz-\nSteuer"
/// stays two words). A soft hyphen (U+00AD) inside a word is removed ("Steuer\u{AD}bescheid" is `steuerbescheid`;
/// review of #125, N3); at a line end it joins like a hyphen.
///
/// Plain ASCII words are only lowercased (the fast path); other words are normalised once per distinct raw form
/// through `SearchNormalizer.Cache`.
public enum SearchTokenizer {
    /// The normalised words of `text`, in order, repeats included.
    public static func words(of text: String) -> [String] {
        var cache = SearchNormalizer.Cache()
        return words(of: text, cache: &cache)
    }

    public static func words(of text: String, cache: inout SearchNormalizer.Cache) -> [String] {
        var result: [String] = []
        forEachWord(in: text, cache: &cache) { result.append($0) }
        return result
    }

    /// Calls `body` with each normalised word of `text`, in order.
    public static func forEachWord(
        in text: String, cache: inout SearchNormalizer.Cache, _ body: (String) -> Void
    ) {
        forEachRawWord(in: text, joiningLineEndHyphens: true) { bytes, isASCII in
            if isASCII {
                body(lowercasedASCII(bytes))
            } else {
                for token in cache.tokens(ofRawWord: String(decoding: bytes, as: UTF8.self)) { body(token) }
            }
        }
    }

    /// The terms of a query, each once, in the order typed. Every term must match (plan of #7, P1).
    public static func terms(of query: String) -> [SearchTerm] {
        var cache = SearchNormalizer.Cache()
        var result: [SearchTerm] = []
        var seen: Set<SearchTerm> = []
        forEachRawWord(in: query, joiningLineEndHyphens: false) { bytes, isASCII in
            let tokens: [String]
            var transcribed: [String] = []
            // The length the infix rule reads: the characters typed, or a token's own when normalising split
            // the word ("½" → `1`, `2`).
            let typedLength: Int
            if isASCII {
                tokens = [lowercasedASCII(bytes)]
                typedLength = bytes.count
            } else {
                let raw = String(decoding: bytes, as: UTF8.self)
                tokens = cache.tokens(ofRawWord: raw)
                typedLength = raw.count
                if let alternative = SearchNormalizer.transcribed(raw) {
                    transcribed = splitNormalized(SearchNormalizer.normalizedWord(alternative))
                }
            }
            for (index, token) in tokens.enumerated() {
                var forms = [token]
                if let form = SearchNormalizer.detranscribed(token) { forms.append(form) }
                if transcribed.count == tokens.count {
                    forms.append(transcribed[index])
                    if let form = SearchNormalizer.detranscribed(transcribed[index]) { forms.append(form) }
                }
                let term = SearchTerm(forms: forms, typedLength: tokens.count == 1 ? typedLength : token.count)
                if !term.forms.isEmpty, seen.insert(term).inserted { result.append(term) }
            }
        }
        return result
    }

    /// Splits an already normalised string at everything that is not part of a word, without joining hyphens.
    static func splitNormalized(_ normalized: String) -> [String] {
        var result: [String] = []
        var current = ""
        for scalar in normalized.unicodeScalars {
            if isWordScalar(scalar) {
                current.unicodeScalars.append(scalar)
            } else if !current.isEmpty {
                result.append(current)
                current = ""
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    // MARK: Scanning

    /// Letters, digits (any numeric value) and combining marks, so a decomposed "é" stays one word.
    static func isWordScalar(_ scalar: Unicode.Scalar) -> Bool {
        if scalar.isASCII {
            let value = scalar.value
            return (value >= 0x61 && value <= 0x7A) || (value >= 0x41 && value <= 0x5A)
                || (value >= 0x30 && value <= 0x39)
        }
        let properties = scalar.properties
        if properties.isAlphabetic || properties.numericType != nil { return true }
        switch properties.generalCategory {
        case .nonspacingMark, .spacingMark, .enclosingMark: return true
        default: return false
        }
    }

    /// The hyphens that join a word broken at a line end: hyphen-minus, hyphen and soft hyphen.
    private static func isJoiningHyphen(_ scalar: Unicode.Scalar) -> Bool {
        scalar == "-" || scalar == "\u{2010}" || scalar == "\u{00AD}"
    }

    private static func isHorizontalSpace(_ scalar: Unicode.Scalar) -> Bool {
        scalar == " " || scalar == "\t"
    }

    private enum Pending {
        case none
        /// A soft hyphen right after a word: removed when a letter follows at once, otherwise a joining hyphen.
        case softHyphen
        /// A joining hyphen right after a word, maybe followed by spaces.
        case hyphen
        /// … then one line break (`\n`, `\r` or `\r\n`), maybe followed by spaces.
        case lineBreak(afterCR: Bool)
    }

    /// Calls `body` with the UTF-8 bytes of each raw word and whether they are all ASCII.
    static func forEachRawWord(
        in text: String, joiningLineEndHyphens: Bool, _ body: ([UInt8], Bool) -> Void
    ) {
        var word: [UInt8] = []
        var isASCII = true
        var pending = Pending.none

        func flush() {
            guard !word.isEmpty else { return }
            body(word, isASCII)
            word.removeAll(keepingCapacity: true)
            isASCII = true
        }

        func append(_ scalar: Unicode.Scalar) {
            if scalar.isASCII {
                word.append(UInt8(scalar.value))
            } else {
                isASCII = false
                UTF8.encode(scalar) { word.append($0) }
            }
        }

        for scalar in text.unicodeScalars {
            if case .softHyphen = pending {
                if scalar == "\u{00AD}" { continue }
                if isWordScalar(scalar) {
                    pending = .none
                    append(scalar)
                    continue
                }
                pending = joiningLineEndHyphens ? .hyphen : .none
            }
            switch pending {
            case .none, .softHyphen:
                break
            case .hyphen:
                if isHorizontalSpace(scalar) { continue }
                if scalar == "\n" || scalar == "\r" {
                    pending = .lineBreak(afterCR: scalar == "\r")
                    continue
                }
                pending = .none
                flush()
            case .lineBreak(let afterCR):
                if isHorizontalSpace(scalar) { continue }
                if afterCR && scalar == "\n" {
                    pending = .lineBreak(afterCR: false)
                    continue
                }
                pending = .none
                if isWordScalar(scalar) && scalar.properties.isLowercase {
                    append(scalar)
                    continue
                }
                flush()
            }
            if isWordScalar(scalar) {
                append(scalar)
            } else if scalar == "\u{00AD}" && !word.isEmpty {
                pending = .softHyphen
            } else if joiningLineEndHyphens && !word.isEmpty && isJoiningHyphen(scalar) {
                pending = .hyphen
            } else {
                flush()
            }
        }
        flush()
    }

    private static func lowercasedASCII(_ bytes: [UInt8]) -> String {
        String(
            decoding: bytes.map { $0 >= 0x41 && $0 <= 0x5A ? $0 + 0x20 : $0 }, as: UTF8.self)
    }
}
