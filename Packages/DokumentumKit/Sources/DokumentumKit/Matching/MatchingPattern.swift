import Foundation

/// How the word modes (`any`, `all`, `exact`) read a pattern and a text (plan of #10, Approach 2, N2, P4).
///
/// **Words** are the search's: `SearchTokenizer`'s scanning (a hyphen at a line end joins, "Stadt-\nwerke" is one
/// word) and `SearchNormalizer`'s folding (NFKC; case, diacritics and width; ß → ss, æ, ø, ł and the like). Two
/// words are compared whole, as paperless's `\b…\b`: "Amt" is not in "Samt" (P4).
///
/// **Umlauts (N2): transcribed forms on both sides, never detranscribed.** A word has its folded form, and a word
/// written with ä, ö or ü also the folded form of its transcription ("Müller": `muller`, `mueller`). Two words are
/// equal when their forms share one. So "Mueller" matches "Müller" and "Mueller", "Müller" matches "Müller",
/// "Muller" and "Mueller", and "Poet", "Neue" and "Michael" match only themselves.
///
/// **Terms** (`any`, `all`): the pattern split at whitespace; text in double quotes (`"…"`, `„…“`, `“…”`) is one
/// term, an unclosed quote runs to the end. A term of several words matches as consecutive words.
public enum MatchingPattern {
    /// One word: its forms, the folded one first.
    typealias Word = [String]

    /// The terms of an `any` or `all` pattern, as raw text, in order. Empty terms are dropped.
    public static func terms(of pattern: String) -> [String] {
        var terms: [String] = []
        var current = ""
        var quoted = false
        func flush() {
            if !current.isEmpty { terms.append(current) }
            current = ""
        }
        for character in pattern {
            if quoted {
                if closingQuotes.contains(character) {
                    quoted = false
                    flush()
                } else {
                    current.append(character)
                }
            } else if openingQuotes.contains(character) {
                flush()
                quoted = true
            } else if character.isWhitespace {
                flush()
            } else {
                current.append(character)
            }
        }
        flush()
        return terms
    }

    static let openingQuotes: Set<Character> = ["\"", "\u{201E}", "\u{201C}"]
    static let closingQuotes: Set<Character> = ["\"", "\u{201C}", "\u{201D}"]

    /// The words of a term or of an `exact` pattern, each with its forms. Quotes and punctuation separate words.
    static func words(of string: String) -> [Word] {
        var cache = SearchNormalizer.Cache()
        var result: [Word] = []
        SearchTokenizer.forEachRawWord(in: string, joiningLineEndHyphens: false) { bytes, isASCII in
            result += forms(ofRawWord: bytes, isASCII: isASCII, cache: &cache)
        }
        return result
    }

    /// The forms of the tokens one raw word gives: usually one token, more when normalising split it ("½").
    static func forms(ofRawWord bytes: [UInt8], isASCII: Bool, cache: inout SearchNormalizer.Cache) -> [Word] {
        // A plain ASCII word has no umlaut: lowercased only, as the tokenizer's fast path.
        if isASCII {
            return [[String(decoding: bytes.map { $0 >= 0x41 && $0 <= 0x5A ? $0 + 0x20 : $0 }, as: UTF8.self)]]
        }
        let raw = String(decoding: bytes, as: UTF8.self)
        let tokens = cache.tokens(ofRawWord: raw)
        var transcribed: [String] = []
        if let alternative = SearchNormalizer.transcribed(raw) {
            transcribed = SearchTokenizer.splitNormalized(SearchNormalizer.normalizedWord(alternative))
        }
        return tokens.enumerated().map { index, token in
            guard transcribed.count == tokens.count, transcribed[index] != token else { return [token] }
            return [token, transcribed[index]]
        }
    }
}

/// A document's text as the word modes read it: its words with their forms, and where each form occurs. Built once
/// per document, and only when a word rule exists.
struct MatchingText {
    private let words: [MatchingPattern.Word]
    private let positions: [String: [Int]]

    init(_ text: String) {
        var cache = SearchNormalizer.Cache()
        var words: [MatchingPattern.Word] = []
        var positions: [String: [Int]] = [:]
        SearchTokenizer.forEachRawWord(in: text, joiningLineEndHyphens: true) { bytes, isASCII in
            for word in MatchingPattern.forms(ofRawWord: bytes, isASCII: isASCII, cache: &cache) {
                for form in word { positions[form, default: []].append(words.count) }
                words.append(word)
            }
        }
        self.words = words
        self.positions = positions
    }

    /// Whether `phrase` occurs as consecutive words. An empty phrase never does.
    func contains(_ phrase: [MatchingPattern.Word]) -> Bool {
        guard let first = phrase.first else { return false }
        var starts = Set<Int>()
        for form in first { starts.formUnion(positions[form] ?? []) }
        return starts.contains { start in
            guard start + phrase.count <= words.count else { return false }
            return phrase.indices.dropFirst().allSatisfy { offset in
                !Set(words[start + offset]).isDisjoint(with: phrase[offset])
            }
        }
    }
}
