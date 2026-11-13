import DokumentumKit
import Foundation
import Testing

/// The regular-expression guard (plan of #10, T8, review N3 a): invalid patterns are skipped, never thrown or
/// trapped; a catastrophic pattern stops at its budget. Every case is bounded: without the guard the catastrophic
/// cases return after a few seconds as "no match" and fail, they never hang (26 × "a" + "!" for `(a+)+$`).
struct RegexMatcherTests {
    /// The plan's P-2: exponential backtracking on 26 × "a" + "!".
    static let catastrophic = "(a+)+$"
    static let catastrophicText = String(repeating: "a", count: 26) + "!"

    /// The plan's P-3 and R-3: each throws when compiled; here each is `nil`.
    @Test(arguments: ["(abc", "(?<=a+)b", "a{1,100000}{1,100000}", "[z-a]", "*"])
    func anInvalidPatternIsNilAndNeverThrows(pattern: String) {
        #expect(RegexMatcher.compile(pattern) == nil)
        #expect(RegexMatcher.firstMatch(of: pattern, in: "abc", budget: .production) == nil)
    }

    /// The callback budget, without a clock: only this test uses it (counter-proof: no `.reportProgress`).
    @Test func aCatastrophicPatternStopsAtACallbackBudget() {
        #expect(
            RegexMatcher.firstMatch(of: Self.catastrophic, in: Self.catastrophicText, budget: .progressCallbacks(1_000))
                == .timedOut)
    }

    /// The production budget, on the real clock: 100 ms (counter-proof: no `.reportProgress`).
    @Test func aCatastrophicPatternStopsAtTheClockBudget() {
        #expect(
            RegexMatcher.firstMatch(of: Self.catastrophic, in: Self.catastrophicText, budget: .production) == .timedOut)
    }

    /// N3 a: an ordinary pattern that finds nothing in a 500,000-byte text is not timed out under the production
    /// budget, although the progress block runs once per start position (counter-proof: a callback budget in
    /// production).
    @Test func anOrdinaryPatternOnACappedTextIsNotTimedOut() {
        let line = "Sehr geehrte Frau Muster, anbei erhalten Sie Ihre Jahresabrechnung für Strom 2025.\n"
        let text = String(repeating: line, count: 500_000 / line.utf8.count)
        #expect(text.utf8.count > 490_000)
        #expect(RegexMatcher.firstMatch(of: "IBAN\\s*DE\\d{20}", in: text, budget: .production) == .noMatch)
        #expect(RegexMatcher.firstMatch(of: "Strom\\s+2025", in: text, budget: .production) == .match)
    }

    @Test func onlyAMatchCountsAsAMatch() {
        #expect(RegexMatcher.firstMatch(of: "rechnung", in: "Ihre RECHNUNG", budget: .production) == .match)
        #expect(RegexMatcher.firstMatch(of: "rechnung", in: "Ihre Abrechnungen", budget: .production) == .match)
        #expect(RegexMatcher.firstMatch(of: "\\brechnung\\b", in: "Ihre Abrechnung", budget: .production) == .noMatch)
    }
}
