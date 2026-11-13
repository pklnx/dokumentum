import DokumentumKit
import Foundation
import Testing

/// What the editor checks before it saves a rule (plan of #10, §8, T8).
struct MatchingRuleValidationTests {
    @Test func aValidRuleHasNoProblem() async {
        #expect(MatchingRuleValidation.check(mode: .regex, pattern: "Stadtwerke\\s+M(ü|ue)nchen") == nil)
        #expect(MatchingRuleValidation.probe(regex: "Stadtwerke\\s+M(ü|ue)nchen") == nil)
        #expect(await MatchingRuleValidation.probeConcurrently(regex: "IBAN\\s*DE\\d{20}") == nil)
        #expect(MatchingRuleValidation.check(mode: .any, pattern: "(abc") == nil, "a word pattern is not compiled")
        #expect(
            MatchingRuleValidation.check(mode: .regex, pattern: "") == nil, "empty: never matches, nothing to check")
    }

    @Test func anInvalidRegularExpressionIsReported() {
        #expect(MatchingRuleValidation.check(mode: .regex, pattern: "(abc") == .invalidRegularExpression)
        #expect(MatchingRuleValidation.probe(regex: "(abc") == .invalidRegularExpression)
    }

    @Test func aPatternOverTheLimitIsReportedInEveryModeWithAPattern() {
        let limit = String(repeating: "a", count: MatchingLimits.patternLength)
        for mode in [MatchMode.any, .all, .exact, .regex] {
            #expect(MatchingRuleValidation.check(mode: mode, pattern: limit) == nil, "\(mode)")
            #expect(MatchingRuleValidation.check(mode: mode, pattern: limit + "a") == .tooLong, "\(mode)")
        }
        #expect(MatchingRuleValidation.check(mode: .none, pattern: limit + "a") == nil, "no rule, nothing to check")
    }

    /// A pattern that runs out of the budget on a probe text is too slow. The text is bounded (26 × "a" + "!"), so
    /// without the guard this fails after a few seconds instead of hanging; the real probe texts are longer.
    @Test func aCatastrophicPatternIsTooSlow() async {
        let pattern = "(a+)+$"
        #expect(MatchingRuleValidation.check(mode: .regex, pattern: pattern) == nil, "it compiles")
        let bounded = [String(repeating: "a", count: 26) + "!"]
        #expect(await MatchingRuleValidation.probeConcurrently(regex: pattern, texts: bounded) == .tooSlow)
    }

    /// The probe texts hold the adversarial inputs of the plan's P-2 and R-1, and ordinary text that ordinary
    /// patterns run through within the budget.
    @Test func theProbeTextsHoldTheAdversarialInputs() {
        let texts = MatchingRuleValidation.probeTexts
        #expect(texts.contains(String(repeating: "a", count: 40) + "!"))
        #expect(texts.contains(String(repeating: "x", count: 5_000)))
        #expect(texts.contains(String(repeating: "x,", count: 3_000)))
        #expect(texts.contains { $0.contains("Stadtwerke München") })
        for pattern in ["\\d{2}\\.\\d{2}\\.\\d{4}", "(Strom|Gas)\\s+\\d+", "^Invoice", "Rechnung\\s+\\w+"] {
            #expect(MatchingRuleValidation.probe(regex: pattern) == nil, "\(pattern)")
        }
    }
}
