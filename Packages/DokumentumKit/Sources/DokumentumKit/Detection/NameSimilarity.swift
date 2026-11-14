import Foundation

/// Whether two names differ only by an OCR misread (review B4 and B5 of #209): a small 6–8 pt line such as a
/// return-address line is often read a letter or two off (`Finanzamt Musterstact`, `Stadtbibliothek Musterstad!`).
///
/// **Near-equal:** both names folded (`SuggestionRules.fold`) and split into words (runs of letters and digits);
/// the same number of words, at least one; and each pair of words equal, or within an edit distance (Levenshtein,
/// per character) that depends on the word's length, the longer of the two:
/// - up to 3 characters: equal only (`AG`, `SE`, `der`);
/// - 4 to 7 characters: at most 1 edit (`GmbH`, `Muster`);
/// - 8 characters or more: at most 2 edits (`Musterstadt`, `Stadtbibliothek`).
///
/// Punctuation is not a word, so `Musterstad!` is the word `musterstad`. A different word count is never near-equal,
/// so a letterhead name with another word (`Inkasso Beispiel GmbH` against `Stadtwerke Musterstadt GmbH`) never is.
public enum NameSimilarity {
    /// The edits allowed for a word of `length` characters.
    public static func allowedEdits(forLength length: Int) -> Int {
        switch length {
        case ...3: 0
        case 4...7: 1
        default: 2
        }
    }

    public static func isNearEqual(_ lhs: String, _ rhs: String) -> Bool {
        let left = words(lhs)
        let right = words(rhs)
        guard !left.isEmpty, left.count == right.count else { return false }
        return zip(left, right).allSatisfy { a, b in
            a == b || distance(a, b, limit: allowedEdits(forLength: max(a.count, b.count))) != nil
        }
    }

    static func words(_ name: String) -> [[Character]] {
        SuggestionRules.fold(name).split { !($0.isLetter || $0.isNumber) }.map(Array.init)
    }

    /// The edit distance of `a` and `b` when it is at most `limit`, else `nil`.
    static func distance(_ a: [Character], _ b: [Character], limit: Int) -> Int? {
        guard abs(a.count - b.count) <= limit else { return nil }
        var previous = Array(0...b.count)
        for (i, x) in a.enumerated() {
            var current = [i + 1] + Array(repeating: 0, count: b.count)
            for (j, y) in b.enumerated() {
                current[j + 1] = min(previous[j + 1] + 1, current[j] + 1, previous[j] + (x == y ? 0 : 1))
            }
            previous = current
        }
        return previous[b.count] <= limit ? previous[b.count] : nil
    }
}
