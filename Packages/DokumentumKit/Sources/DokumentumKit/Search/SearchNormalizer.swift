import Foundation

/// How the search compares words (plan of #7, Approach 5, T4): the same for the index and for a query, and the
/// same on every device, whatever its language.
///
/// A word goes through NFKC (ligatures, full-width and other compatibility forms), then Foundation's folding of
/// case, diacritics and width with `locale: nil`, then a table for the letters folding leaves alone (æ, œ, ø, ł,
/// đ, þ, and ß as a guard). The result is in NFC, so equal words have equal bytes. The Turkish dotless ı stays as
/// folding leaves it.
public enum SearchNormalizer {
    /// What folding leaves unchanged and the search still treats as plain letters.
    static let table: [Unicode.Scalar: String] = [
        "æ": "ae", "Æ": "ae", "œ": "oe", "Œ": "oe", "ø": "o", "Ø": "o", "ł": "l", "Ł": "l", "đ": "d", "Đ": "d",
        "þ": "th", "Þ": "th", "ß": "ss", "ẞ": "ss",
    ]

    /// The normalised form of `word`. It can contain characters that separate words (NFKC turns "½" into
    /// "1⁄2"): the tokeniser splits the result again.
    public static func normalizedWord(_ word: String) -> String {
        let folded = word.precomposedStringWithCompatibilityMapping
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        guard folded.unicodeScalars.contains(where: { table[$0] != nil }) else {
            return folded.precomposedStringWithCanonicalMapping
        }
        var result = ""
        for scalar in folded.unicodeScalars {
            if let replacement = table[scalar] {
                result += replacement
            } else {
                result.unicodeScalars.append(scalar)
            }
        }
        return result.precomposedStringWithCanonicalMapping
    }

    /// A normalised token with each *ae*, *oe* and *ue* read as the umlaut it transcribes (Revision 1, B1):
    /// `mueller` → `muller`, the form "Müller" folds to. `nil` when the token has none.
    public static func detranscribed(_ token: String) -> String? {
        var bytes = Array(token.utf8)
        var found = false
        var write = 0
        var read = 0
        while read < bytes.count {
            let byte = bytes[read]
            bytes[write] = byte
            write += 1
            read += 1
            if byte == UInt8(ascii: "a") || byte == UInt8(ascii: "o") || byte == UInt8(ascii: "u"),
                read < bytes.count, bytes[read] == UInt8(ascii: "e")
            {
                read += 1
                found = true
            }
        }
        guard found else { return nil }
        return String(decoding: bytes[..<write], as: UTF8.self)
    }

    /// `word` with ä, ö and ü written as *ae*, *oe* and *ue*, the transcription a query also tries (plan of #7,
    /// Approach 4). `nil` when the word has none of them.
    public static func transcribed(_ word: String) -> String? {
        let composed = word.precomposedStringWithCanonicalMapping
        let map: [Unicode.Scalar: String] = ["ä": "ae", "Ä": "Ae", "ö": "oe", "Ö": "Oe", "ü": "ue", "Ü": "Ue"]
        guard composed.unicodeScalars.contains(where: { map[$0] != nil }) else { return nil }
        var result = ""
        for scalar in composed.unicodeScalars {
            if let replacement = map[scalar] {
                result += replacement
            } else {
                result.unicodeScalars.append(scalar)
            }
        }
        return result
    }

    /// Normalised words by their raw form, for words that are not plain ASCII (P-h: folding each distinct form
    /// once makes a build several times faster). It lives for one build or one batch of updates.
    public struct Cache: Sendable {
        private var words: [String: [String]] = [:]

        public init() {}

        /// The distinct raw words held.
        public var count: Int { words.count }

        /// The normalised tokens of one raw word: usually one, more when normalising produced a separator.
        mutating func tokens(ofRawWord raw: String) -> [String] {
            if let known = words[raw] { return known }
            let tokens = SearchTokenizer.splitNormalized(SearchNormalizer.normalizedWord(raw))
            words[raw] = tokens
            return tokens
        }

        public mutating func removeAll() {
            words.removeAll()
        }
    }
}
