import Foundation

/// The written month names, folded (`SuggestionRules.fold`), in German and English: one table for the
/// classification's date check (`DateForms`) and the issue-date parser (`IssueDateDetector`, #11).
///
/// Each month lists its full name, its other spellings (`Jänner`, `Feber`) and its abbreviations (`Sept`, `Sep`);
/// a written abbreviation may carry a dot, which the users of this table allow themselves.
public enum MonthNames {
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

    /// Every name of `month` (1…12), German and English, without duplicates.
    static func names(of month: Int) -> [String] {
        var names: [String] = []
        for name in german[month - 1] + english[month - 1] where !names.contains(name) { names.append(name) }
        return names
    }

    /// The month (1…12) a folded word names, or `nil`.
    static func month(named folded: String) -> Int? {
        byName[folded]
    }

    private static let byName: [String: Int] = {
        var table: [String: Int] = [:]
        for month in 1...12 {
            for name in names(of: month) { table[name] = month }
        }
        return table
    }()
}
