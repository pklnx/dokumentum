import DokumentumKit
import Foundation
import Testing

/// The rules per mode, with normalisation, transcribed forms, whole words and the ambiguity rule (plan of #10,
/// Tests part 1b, Kit). Pinned outputs: `kit-linux` runs them too.
struct MatchingRulesTests {
    static func rule(
        _ mode: MatchMode, _ pattern: String, kind: MetadataKind = .tag, id: UUID = UUID(), name: String = "Rule"
    ) -> MatchingRule {
        MatchingRule(id: id, kind: kind, name: name, mode: mode, pattern: pattern)
    }

    /// Whether a single tag rule matches `text`.
    static func matches(_ mode: MatchMode, _ pattern: String, _ text: String) -> Bool {
        let rule = rule(mode, pattern)
        return MatchingRules.evaluate(text: text, rules: [rule], budget: generousBudget).tags == [rule.id]
    }

    // MARK: Per mode

    @Test(arguments: [
        ("Stadtwerke Telekom", "Ihre Rechnung der Stadtwerke", true),
        ("Telekom Vodafone", "Ihre Rechnung der Stadtwerke", false),
        ("\"Stadtwerke München\" Telekom", "Stadtwerke München GmbH", true),
        ("\"Stadtwerke München\" Telekom", "Stadtwerke in München", false),
        ("„Stadtwerke München“", "die Stadtwerke München", true),
    ])
    func anyWord(pattern: String, text: String, expected: Bool) {
        #expect(Self.matches(.any, pattern, text) == expected)
    }

    @Test(arguments: [
        ("Rechnung Strom", "Strom: Ihre Rechnung", true),
        ("Rechnung Strom Gas", "Strom: Ihre Rechnung", false),
        ("\"Ihre Rechnung\" Strom", "Strom: Ihre Rechnung", true),
    ])
    func allWords(pattern: String, text: String, expected: Bool) {
        #expect(Self.matches(.all, pattern, text) == expected)
    }

    @Test(arguments: [
        ("Stadtwerke München", "Die Stadtwerke München GmbH", true),
        ("München Stadtwerke", "Die Stadtwerke München GmbH", false),
        ("\"Stadtwerke München\"", "Die Stadtwerke München GmbH", true),
        ("Stadtwerke", "Ihre Stadt-\nwerke München", true),
        ("Stadt Werke", "Ihre Stadt-\nwerke München", false),
    ])
    func exactPhrase(pattern: String, text: String, expected: Bool) {
        #expect(Self.matches(.exact, pattern, text) == expected)
    }

    @Test(arguments: [
        ("stadtwerke\\s+m(ü|ue)nchen", "Rechnung der STADTWERKE  MÜNCHEN GmbH", true),
        ("IBAN\\s*DE\\d{20}", "IBAN DE02120300000000202051 bitte", true),
        ("IBAN\\s*DE\\d{20}", "IBAN DE0212030000000020205 bitte", false),
        ("werke", "Stadtwerke", true),
        ("\\d{2}\\.\\d{2}\\.2026", "vom 14-01-2026", false),
    ])
    func regularExpression(pattern: String, text: String, expected: Bool) {
        #expect(Self.matches(.regex, pattern, text) == expected)
    }

    @Test func noneAnEmptyPatternAndUnknownNeverMatch() {
        // Double spaces: a whitespace-only regular expression would match them.
        let text = "Stadtwerke  München  \"\"  "
        #expect(!Self.matches(.none, "Stadtwerke", text))
        #expect(!Self.matches(.unknown, "Stadtwerke", text))
        for mode in [MatchMode.any, .all, .exact, .regex] {
            #expect(!Self.matches(mode, "", text), "\(mode)")
            #expect(!Self.matches(mode, "  ", text), "\(mode)")
        }
        for mode in [MatchMode.any, .all, .exact] {
            #expect(!Self.matches(mode, "\"\" „“", text), "\(mode): only quotes")
        }
    }

    // MARK: Normalisation

    @Test(arguments: [
        ("Stadtwerke", "STADTWERKE"),
        ("München", "MÜNCHEN"),
        ("München", "Munchen"),
        ("MÜNCHEN", "München"),
        ("Straße", "STRASSE"),
        ("strasse", "Straße"),
        ("München", "Mu\u{308}nchen"),
        ("Mu\u{308}nchen", "München"),
        ("Müller", "Mueller"),
        ("Mueller", "Müller"),
        ("Muller", "Müller"),
        ("Müller", "Muller"),
        ("Mueller", "Mu\u{308}ller"),
    ])
    func wordsAreFolded(pattern: String, text: String) {
        for mode in [MatchMode.any, .all, .exact] {
            #expect(Self.matches(mode, pattern, "Herr \(text) GmbH"), "\(mode)")
        }
    }

    /// N2: transcribed forms on both sides, never detranscribed (counter-proof: `detranscribed` on the pattern).
    @Test(arguments: [
        ("Poet", "Pot"), ("Neue", "neu"), ("Michael", "Michal"), ("Treue", "treu"), ("Mueller", "Muller"),
    ])
    func aTranscriptionIsNeverUndone(pattern: String, text: String) {
        #expect(!Self.matches(.any, pattern, "Herr \(text) GmbH"))
        #expect(Self.matches(.any, pattern, "Herr \(pattern) GmbH"))
    }

    /// P4: whole words only.
    @Test(arguments: [("Amt", "Samt und Seide"), ("Strom", "Ihre Stromrechnung"), ("Rechnung", "Stromrechnungen")])
    func onlyWholeWordsMatch(pattern: String, text: String) {
        for mode in [MatchMode.any, .all, .exact] {
            #expect(!Self.matches(mode, pattern, text), "\(mode)")
        }
        #expect(Self.matches(.any, pattern, "\(text) \(pattern)."))
    }

    // MARK: Regular expressions (B2)

    @Test func aRegularExpressionIsCaseInsensitive() {
        #expect(Self.matches(.regex, "stadtwerke", "STADTWERKE"))
        #expect(Self.matches(.regex, "MÜNCHEN", "münchen"))
    }

    /// A PDF's decomposed umlaut is found by a composed pattern, and the other way round (counter-proof: no NFC).
    @Test func aRegularExpressionRunsOnTheNFCText() {
        #expect(Self.matches(.regex, "München", "Stadtwerke Mu\u{308}nchen GmbH"))
        #expect(Self.matches(.regex, "Mu\u{308}nchen", "Stadtwerke München GmbH"))
        #expect(Self.matches(.regex, "Stadtwerke M.nchen", "Stadtwerke Mu\u{308}nchen GmbH"))
    }

    /// P4: accents and ae/oe/ue count as written in a regular expression.
    @Test func aRegularExpressionTakesAccentsAsWritten() {
        #expect(!Self.matches(.regex, "Müller", "Herr Mueller"))
        #expect(!Self.matches(.regex, "Müller", "Herr Muller"))
        #expect(Self.matches(.regex, "M(ü|ue)ller", "Herr Mueller"))
    }

    @Test func anInvalidRuleIsReportedAndTheOthersApply() {
        let broken = Self.rule(.regex, "(abc")
        let long = Self.rule(.any, String(repeating: "a ", count: 600))
        let good = Self.rule(.any, "Strom")
        let outcome = MatchingRules.evaluate(text: "abc Strom", rules: [broken, long, good], budget: generousBudget)
        #expect(outcome.invalid == [broken.id, long.id])
        #expect(outcome.tags == [good.id])
    }

    // MARK: Ambiguity (P2)

    @Test func twoMatchingCorrespondentsGiveNone() {
        let first = Self.rule(.any, "Stadtwerke", kind: .correspondent)
        let second = Self.rule(.any, "München", kind: .correspondent)
        let outcome = MatchingRules.evaluate(
            text: "Stadtwerke München", rules: [first, second], budget: generousBudget)
        #expect(outcome.correspondent == nil)
        #expect(outcome.ambiguous == [.correspondent])
    }

    @Test func aCorrespondentAndATypeAreBothSetAndEveryTagIsAdded() {
        let correspondent = Self.rule(.any, "Stadtwerke", kind: .correspondent)
        let type = Self.rule(.any, "Rechnung", kind: .documentType)
        let otherType = Self.rule(.any, "Vertrag", kind: .documentType)
        let strom = Self.rule(.any, "Strom")
        let energie = Self.rule(.regex, "stadt\\w+")
        let gas = Self.rule(.any, "Gas")
        let outcome = MatchingRules.evaluate(
            text: "Stadtwerke Rechnung Strom", rules: [correspondent, type, otherType, strom, energie, gas],
            budget: generousBudget)
        #expect(outcome.correspondent == correspondent.id)
        #expect(outcome.documentType == type.id)
        #expect(outcome.tags == [strom.id, energie.id])
        #expect(outcome.ambiguous.isEmpty)
    }

    /// T7: every order of the same rules gives the same outcome (counter-proof: the first match in input order).
    @Test func everyPermutationOfTheRulesGivesTheSameOutcome() {
        let rules = [
            Self.rule(.any, "Stadtwerke", kind: .correspondent),
            Self.rule(.all, "München Strom", kind: .correspondent),
            Self.rule(.exact, "Jahresabrechnung Strom", kind: .documentType),
            Self.rule(.regex, "stadt\\w+", kind: .tag),
            Self.rule(.any, "Gas Strom", kind: .tag),
            Self.rule(.regex, "(broken", kind: .tag),
        ]
        let text = "Stadtwerke München Jahresabrechnung Strom"
        let expected = MatchingRules.evaluate(text: text, rules: rules, budget: generousBudget)
        #expect(expected.ambiguous == [.correspondent])
        #expect(expected.documentType == rules[2].id)
        for permutation in Self.permutations(rules) {
            #expect(MatchingRules.evaluate(text: text, rules: permutation, budget: generousBudget) == expected)
        }
    }

    // MARK: Fix round 1 of #205

    /// A synced rule with a back-reference is skipped as invalid (review B, N1).
    @Test func aBackReferenceRuleIsInvalidAtRunTime() {
        let rule = Self.rule(.regex, "(Strom)\\1")
        let outcome = MatchingRules.evaluate(text: "StromStrom", rules: [rule], budget: generousBudget)
        #expect(outcome.invalid == [rule.id])
        #expect(outcome.tags.isEmpty)
    }

    static let slowText = "Stadtwerke München " + String(repeating: "a", count: 26) + "!"

    /// Review A, N4: a correspondent rule that times out makes the kind ambiguous, so the other matching record is not
    /// set alone and the value does not depend on the device's speed (counter-proof: a timed-out rule counts as no
    /// match). The type is decided as usual.
    @Test func aTimedOutCorrespondentRuleMakesTheKindAmbiguous() {
        let matching = Self.rule(.any, "Stadtwerke", kind: .correspondent)
        let slow = Self.rule(.regex, "(a+)+$", kind: .correspondent)
        let type = Self.rule(.any, "München", kind: .documentType)
        let outcome = MatchingRules.evaluate(
            text: Self.slowText, rules: [matching, slow, type], budget: .progressCallbacks(1_000))
        #expect(outcome.timedOut == [slow.id])
        #expect(outcome.correspondent == nil)
        #expect(outcome.ambiguous == [.correspondent])
        #expect(outcome.documentType == type.id)
    }

    /// Review B, N2: a rule in `skipping` is not run (counter-proof: ignore `skipping`); a skipped correspondent rule
    /// makes its kind ambiguous, as a time-out does (counter-proof: a skipped rule counts as no match).
    @Test func aSkippedRuleIsNotRunAndASkippedCorrespondentRuleIsAmbiguous() {
        let slowTag = Self.rule(.regex, "(a+)+$")
        let strom = Self.rule(.any, "München")
        let matching = Self.rule(.any, "Stadtwerke", kind: .correspondent)
        let slowCorrespondent = Self.rule(.regex, "(a+)+$", kind: .correspondent)
        let prepared = MatchingRules.Prepared([slowTag, strom, matching, slowCorrespondent])

        let outcome = prepared.evaluate(
            text: Self.slowText, budget: .progressCallbacks(1_000), skipping: [slowTag.id, slowCorrespondent.id])

        #expect(outcome.timedOut.isEmpty, "skipped rules are not run")
        #expect(outcome.tags == [strom.id])
        #expect(outcome.correspondent == nil)
        #expect(outcome.ambiguous == [.correspondent])
    }

    static func permutations<T>(_ items: [T]) -> [[T]] {
        guard items.count > 1 else { return [items] }
        return items.indices.flatMap { index in
            var rest = items
            let item = rest.remove(at: index)
            return permutations(rest).map { [item] + $0 }
        }
    }
}
