import Foundation

/// How long a regular expression may run on one text (plan of #10, T8, review N3 a).
public enum MatchingBudget: Sendable, Hashable {
    /// Production, and every test of an ordinary pattern: the time on the clock. The progress block runs once per
    /// start position (R-2 of the plan: 1.1 million times for an ordinary no-match on a 1.1-million-character text),
    /// so only the clock tells an ordinary rule on a long text from a catastrophic one.
    case clock(Duration)
    /// Only for the catastrophic-pattern test, which then needs no clock: the match stops after this many progress
    /// callbacks. Never in production: it would time out ordinary rules on long texts.
    case progressCallbacks(Int)

    /// 100 ms per rule and document (P-2, R-1 of the plan).
    public static let production = MatchingBudget.clock(MatchingLimits.regexBudget)
}

/// The regular-expression mode (plan of #10, Approach 2, B2, T8).
///
/// - `NSRegularExpression` with `.caseInsensitive`, on the **NFC form** of the text, and the pattern in NFC too: a
///   PDF's decomposed "München" is found by `München`. Neither text nor pattern is case-folded (that would turn
///   `\S`, `\W`, `\D` and `\B` into their opposites), so punctuation and digits count as written, and accents and
///   ae/oe/ue count as written: `Müller` does not find "Mueller" (P4; write `M(ü|ue)ller`).
/// - Only the first match is looked for.
/// - **The guard:** `enumerateMatches(options: .reportProgress)` stops once the budget is spent; the rule then does
///   not match this text (`timedOut`).
/// - **Never a crash:** a pattern that arrives by sync can be invalid, so it is compiled at every use and a failure
///   means "skipped" (`compile` returns `nil`), never `try!`.
public enum RegexMatcher {
    public enum Result: Sendable, Equatable {
        case match
        case noMatch
        /// The budget ran out first: counts as no match.
        case timedOut
    }

    /// The compiled pattern, or `nil` when it is not a valid regular expression.
    public static func compile(_ pattern: String) -> NSRegularExpression? {
        try? NSRegularExpression(pattern: pattern.precomposedStringWithCanonicalMapping, options: [.caseInsensitive])
    }

    /// Looks for the first match of `regex` in `text`, which the caller has put in NFC
    /// (`precomposedStringWithCanonicalMapping`, once per document).
    public static func firstMatch(of regex: NSRegularExpression, inNFC text: String, budget: MatchingBudget) -> Result {
        let clock = ContinuousClock()
        let start = clock.now
        var callbacks = 0
        var result = Result.noMatch
        regex.enumerateMatches(in: text, options: [.reportProgress], range: NSRange(text.startIndex..., in: text)) {
            match, _, stop in
            if match != nil {
                result = .match
                stop.pointee = true
                return
            }
            callbacks += 1
            let spent: Bool
            switch budget {
            // Every 8th callback: an ordinary pattern on a long text calls back once per start position, while a
            // catastrophic one calls back about ten times per millisecond (P-2), so the stop comes at most about a
            // millisecond late.
            case .clock(let limit): spent = callbacks % 8 == 0 && clock.now - start >= limit
            case .progressCallbacks(let limit): spent = callbacks >= limit
            }
            if spent {
                result = .timedOut
                stop.pointee = true
            }
        }
        return result
    }

    /// `pattern` compiled and run on `text` (NFC applied here); `nil` when the pattern is invalid.
    public static func firstMatch(of pattern: String, in text: String, budget: MatchingBudget) -> Result? {
        guard let regex = compile(pattern) else { return nil }
        return firstMatch(of: regex, inNFC: text.precomposedStringWithCanonicalMapping, budget: budget)
    }
}
