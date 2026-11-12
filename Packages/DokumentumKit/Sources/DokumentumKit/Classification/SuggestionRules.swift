import Foundation

/// A suggestion after `SuggestionRules`: only values that may be written. Names are not matched to records yet
/// (`MetadataMatcher` does that against the live records at the write).
public struct CheckedSuggestion: Equatable, Sendable {
    public var title: String?
    public var correspondent: String?
    public var documentType: String?
    /// At most `ClassificationLimits.tags`, without duplicates (by `MetadataName.normalized`).
    public var tags: [String]
    public var issueDate: SuggestedDate?

    public init(
        title: String? = nil, correspondent: String? = nil, documentType: String? = nil, tags: [String] = [],
        issueDate: SuggestedDate? = nil
    ) {
        self.title = title
        self.correspondent = correspondent
        self.documentType = documentType
        self.tags = tags
        self.issueDate = issueDate
    }

    public var isEmpty: Bool {
        title == nil && correspondent == nil && documentType == nil && tags.isEmpty && issueDate == nil
    }
}

/// The checks every suggested value passes before it is used (plan of #8, Approach 4, T10). A value that fails
/// is dropped; the others stay.
///
/// - **title:** trimmed; empty or a placeholder is dropped; longer than 80 characters is cut at the last word
///   boundary within 80 (at 80 characters when there is none).
/// - **correspondent:** trimmed, at most 80 characters, no placeholder, and **it occurs in the text** (both
///   folded as the search folds words, whitespace collapsed): a model invents senders for texts that name none
///   (P-h).
/// - **document type:** trimmed, at most 40 characters and 3 words, no placeholder.
/// - **tags:** trimmed, non-empty, without duplicates, at most 3, in the model's order. Whether a tag exists is
///   decided at the write against the live tags; tags are never created (P1).
/// - **date:** a valid Gregorian date with a year from 1900 to next year (by `now`), and **it occurs in the text**
///   in one of the usual forms (`DateForms`).
public enum SuggestionRules {
    public static func check(_ suggestion: ClassificationSuggestion, text: String, now: Date) -> CheckedSuggestion {
        let folded = fold(text)
        var checked = CheckedSuggestion()
        checked.title = title(suggestion.title)
        if let name = plain(suggestion.correspondent, limit: ClassificationLimits.correspondentCharacters),
            occurs(name, inFolded: folded)
        {
            checked.correspondent = name
        }
        if let type = plain(suggestion.documentType, limit: ClassificationLimits.documentTypeCharacters),
            words(of: type).count <= ClassificationLimits.documentTypeWords
        {
            checked.documentType = type
        }
        var seen: Set<String> = []
        for tag in suggestion.tags {
            let name = tag.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = MetadataName.normalized(name)
            guard !key.isEmpty, seen.insert(key).inserted else { continue }
            checked.tags.append(name)
            if checked.tags.count == ClassificationLimits.tags { break }
        }
        if let date = suggestion.issueDate, isValid(date, now: now), DateForms.occurs(date, inFolded: folded) {
            checked.issueDate = date
        }
        return checked
    }

    /// The title, or `nil`.
    static func title(_ value: String?) -> String? {
        guard let value else { return nil }
        let title = normalizedTitle(value)
        guard !title.isEmpty, !isPlaceholder(title) else { return nil }
        guard title.count > ClassificationLimits.titleCharacters else { return title }
        let head = title.prefix(ClassificationLimits.titleCharacters)
        // The next character after the head: a space there means the head ends with a whole word.
        let next = title[head.endIndex]
        if next.isWhitespace { return normalizedTitle(String(head)) }
        guard let space = head.lastIndex(where: \.isWhitespace) else { return String(head) }
        let cut = normalizedTitle(String(head[..<space]))
        return cut.isEmpty ? String(head) : cut
    }

    /// A trimmed name within `limit` characters that is no placeholder, or `nil`.
    static func plain(_ value: String?, limit: Int) -> String? {
        guard let value else { return nil }
        let name = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= limit, !isPlaceholder(name) else { return nil }
        return name
    }

    static func isPlaceholder(_ value: String) -> Bool {
        ClassificationLimits.placeholders.contains(MetadataName.normalized(value))
    }

    /// Whether `name` occurs in the text, both folded: as whole words (a name "Amt" does not occur in "Samt").
    static func occurs(_ name: String, inFolded folded: String) -> Bool {
        let needle = fold(name)
        guard !needle.isEmpty else { return false }
        return Folded.containsBounded(needle, in: folded)
    }

    /// Folded as the search folds words, every run of whitespace one space.
    static func fold(_ text: String) -> String {
        SearchNormalizer.normalizedWord(text).split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    static func words(of value: String) -> [Substring] {
        value.split(whereSeparator: \.isWhitespace)
    }

    static func isValid(_ date: SuggestedDate, now: Date) -> Bool {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? calendar.timeZone
        let latest = calendar.component(.year, from: now) + 1
        guard (ClassificationLimits.earliestYear...latest).contains(date.year), (1...12).contains(date.month),
            (1...31).contains(date.day)
        else { return false }
        let components = DateComponents(year: date.year, month: date.month, day: date.day)
        return components.isValidDate(in: calendar)
    }
}

/// Matching in folded text.
enum Folded {
    /// Whether `needle` occurs in `haystack` with no letter or digit right before or after it.
    static func containsBounded(_ needle: String, in haystack: String) -> Bool {
        var searchStart = haystack.startIndex
        while let range = haystack.range(of: needle, range: searchStart..<haystack.endIndex) {
            let before =
                range.lowerBound > haystack.startIndex ? haystack[haystack.index(before: range.lowerBound)] : nil
            let after = range.upperBound < haystack.endIndex ? haystack[range.upperBound] : nil
            if !isWordCharacter(before, next: needle.first), !isWordCharacter(after, next: needle.last) { return true }
            searchStart = haystack.index(after: range.lowerBound)
        }
        return false
    }

    /// A boundary is needed only where the needle itself ends in a letter or digit ("14." may be followed by
    /// "2026" without a space in "14.Januar"; a name ending in "." may touch the next word).
    private static func isWordCharacter(_ character: Character?, next edge: Character?) -> Bool {
        guard let character, let edge, edge.isLetter || edge.isNumber else { return false }
        return character.isLetter || character.isNumber
    }
}

/// The written forms of a date that count as "the text says it" (plan of #8, Approach 4): `14.01.2026`, `14.1.26`,
/// `2026-01-14`, `14. Januar 2026` (also `Jänner`, without the dot, or `Jan.`), `14 January 2026`,
/// `January 14, 2026`. Matched in folded text (case and diacritics ignored), never inside a longer number.
public enum DateForms {
    static let german = [
        ["januar", "janner", "jan"], ["februar", "feber", "feb"], ["marz", "mar"], ["april", "apr"], ["mai"],
        ["juni", "jun"], ["juli", "jul"], ["august", "aug"], ["september", "sept", "sep"], ["oktober", "okt"],
        ["november", "nov"], ["dezember", "dez"],
    ]
    static let english = [
        ["january", "jan"], ["february", "feb"], ["march", "mar"], ["april", "apr"], ["may"], ["june", "jun"],
        ["july", "jul"], ["august", "aug"], ["september", "sept", "sep"], ["october", "oct"],
        ["november", "nov"], ["december", "dec"],
    ]

    /// Every form of `date` this check looks for, folded.
    public static func forms(of date: SuggestedDate) -> [String] {
        let days = Set(["\(date.day)", String(format: "%02d", date.day)])
        let months = Set(["\(date.month)", String(format: "%02d", date.month)])
        let years = ["\(date.year)", String(format: "%02d", date.year % 100)]
        var forms: [String] = []
        for day in days {
            for month in months {
                for year in years { forms.append("\(day).\(month).\(year)") }
            }
        }
        forms.append(String(format: "%04d-%02d-%02d", date.year, date.month, date.day))
        let names = german[date.month - 1] + english[date.month - 1]
        for day in days {
            for name in Set(names) {
                for separator in [". ", " ", "."] {
                    forms.append("\(day)\(separator)\(name) \(date.year)")
                    forms.append("\(day)\(separator)\(name). \(date.year)")
                }
                forms.append("\(name) \(day), \(date.year)")
                forms.append("\(name) \(day) \(date.year)")
                forms.append("\(name). \(day), \(date.year)")
            }
        }
        return forms
    }

    /// Whether `date` occurs in the folded text (`SuggestionRules.fold`).
    static func occurs(_ date: SuggestedDate, inFolded folded: String) -> Bool {
        forms(of: date).contains { Folded.containsBounded($0, in: folded) }
    }

    /// Whether `date` occurs in `text`.
    public static func occurs(_ date: SuggestedDate, in text: String) -> Bool {
        occurs(date, inFolded: SuggestionRules.fold(text))
    }
}
