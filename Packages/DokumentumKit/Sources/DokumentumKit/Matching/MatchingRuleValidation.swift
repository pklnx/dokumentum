import Foundation

/// Whether a rule may be saved (plan of #10, §8, T8). The editor (part 2) shows the problem in its own words and
/// disables Save while there is one.
///
/// - `check`, synchronous, on every change: at most `MatchingLimits.patternLength` characters, and a regular
///   expression must compile.
/// - `probe`, debounced and off the main actor (review N3 b): the regular expression runs on fixed probe texts
///   (the adversarial strings of the plan's P-2 and R-1, and ordinary German and English text) within the run
///   budget; running out of it on any of them is `tooSlow`.
///
/// The matching itself applies `check` again at every use (`MatchingRules.Prepared`): a rule that arrives by sync
/// was never validated on this device.
public enum MatchingRuleValidation {
    public enum Problem: Sendable, Equatable {
        /// Over `MatchingLimits.patternLength` characters.
        case tooLong
        /// "This regular expression is not valid."
        case invalidRegularExpression
        /// "This regular expression takes too long to check."
        case tooSlow
    }

    /// The synchronous checks: length (every mode with a pattern) and compilation (regular expressions). An empty or
    /// whitespace-only pattern is no problem: it never matches.
    public static func check(mode: MatchMode, pattern: String) -> Problem? {
        switch mode {
        case .none, .unknown:
            return nil
        case .any, .all, .exact, .regex:
            guard pattern.count <= MatchingLimits.patternLength else { return .tooLong }
            // An empty pattern never matches and has nothing to compile.
            guard mode == .regex, !pattern.allSatisfy(\.isWhitespace) else { return nil }
            return RegexMatcher.compile(pattern) == nil ? .invalidRegularExpression : nil
        }
    }

    /// The probe run of a regular expression on `texts` (the probe texts; a test passes bounded ones), after
    /// `check`. Synchronous: up to the budget per text.
    public static func probe(
        regex pattern: String, texts: [String] = probeTexts, budget: MatchingBudget = .production
    ) -> Problem? {
        if let problem = check(mode: .regex, pattern: pattern) { return problem }
        guard let regex = RegexMatcher.compile(pattern) else { return .invalidRegularExpression }
        for text in texts
        where RegexMatcher.firstMatch(of: regex, inNFC: text.precomposedStringWithCanonicalMapping, budget: budget)
            == .timedOut
        {
            return .tooSlow
        }
        return nil
    }

    /// `probe(regex:budget:)` off the caller's actor: the editor calls it from the main actor.
    @concurrent
    public static func probeConcurrently(
        regex pattern: String, texts: [String] = probeTexts, budget: MatchingBudget = .production
    ) async -> Problem? {
        probe(regex: pattern, texts: texts, budget: budget)
    }

    /// The fixed probe texts, in NFC: catastrophic and polynomial inputs (plan P-2, review R-1), then ordinary text.
    public static let probeTexts: [String] = [
        String(repeating: "a", count: 40) + "!",
        String(repeating: "x", count: 5_000),
        String(repeating: "x,", count: 3_000),
        Array(repeating: "Wort", count: 30).joined(separator: " ") + " !",
        String(repeating: "a", count: 5_000),
        """
        Stadtwerke München GmbH, Emmy-Noether-Straße 2, 80992 München. Jahresabrechnung Strom 2025, \
        Rechnungsnummer 2026-0042 vom 14.01.2026. IBAN DE02 1203 0000 0000 2020 51. Sehr geehrte Frau Müller, \
        anbei erhalten Sie Ihre Abrechnung über 1.234,56 €.
        """.precomposedStringWithCanonicalMapping,
        """
        Invoice 2026-0042, dated January 14, 2026. Amount due: $1,234.56. Please pay by bank transfer to the \
        account below within 14 days. Thank you for your business!
        """,
    ]
}
