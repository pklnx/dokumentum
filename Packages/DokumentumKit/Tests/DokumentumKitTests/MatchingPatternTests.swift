import DokumentumKit
import Foundation
import Testing

/// How the word modes split a pattern into terms (plan of #10, Approach 2): whitespace separates, double quotes of
/// three kinds hold a phrase, an unclosed quote runs to the end.
struct MatchingPatternTests {
    @Test(arguments: [
        ("Stadtwerke  München\tStrom", ["Stadtwerke", "München", "Strom"]),
        ("\"Stadtwerke München\" Strom", ["Stadtwerke München", "Strom"]),
        ("„Stadtwerke München“ Strom", ["Stadtwerke München", "Strom"]),
        ("“Stadtwerke München” Strom", ["Stadtwerke München", "Strom"]),
        ("Strom \"Stadtwerke München", ["Strom", "Stadtwerke München"]),
        ("a\"b c\"d", ["a", "b c", "d"]),
        ("  \"\"  ", []),
        ("", []),
    ])
    func termsAreSplitAtWhitespaceAndQuotes(pattern: String, expected: [String]) {
        #expect(MatchingPattern.terms(of: pattern) == expected)
    }
}
