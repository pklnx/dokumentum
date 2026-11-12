import DokumentumKit
import Testing

struct SearchTokenizerTests {
    @Test(arguments: [
        ("Kfz-Steuer", ["kfz", "steuer"]),
        ("Kfz\u{2011}Steuer", ["kfz", "steuer"]),
        ("Strom/Gas", ["strom", "gas"]),
        ("Seite 1\u{000C}Seite 2", ["seite", "1", "seite", "2"]),
        ("Ende\u{000C}anfang", ["ende", "anfang"]),
        ("O'Brien's", ["o", "brien", "s"]),
        ("„Rechnung“, bitte!", ["rechnung", "bitte"]),
        ("12.03.2024", ["12", "03", "2024"]),
        ("1.234,56 €", ["1", "234", "56"]),
        ("ABC-123456", ["abc", "123456"]),
        ("   ", []),
        ("", []),
    ])
    func separatorsSplitWords(text: String, expected: [String]) {
        #expect(SearchTokenizer.words(of: text) == expected)
    }

    @Test(arguments: [
        ("Steuer-\nbescheid", ["steuerbescheid"]),
        ("Steuer-\r\nbescheid", ["steuerbescheid"]),
        ("Steuer- \n  bescheid", ["steuerbescheid"]),
        ("Steuer\u{2010}\nbescheid", ["steuerbescheid"]),
        ("Steuer\u{00AD}\nbescheid", ["steuerbescheid"]),
        ("Grund-\nübel", ["grundubel"]),
        ("Kfz-\nSteuer", ["kfz", "steuer"]),
        ("Seite-\n2", ["seite", "2"]),
        ("Steuer-\n\nbescheid", ["steuer", "bescheid"]),
        ("Steuer-\u{000C}bescheid", ["steuer", "bescheid"]),
        ("Steuer- bescheid", ["steuer", "bescheid"]),
        ("-\nbescheid", ["bescheid"]),
        ("Steuer-", ["steuer"]),
    ])
    func aLineEndHyphenJoinsOnlyBeforeALowercaseLetter(text: String, expected: [String]) {
        #expect(SearchTokenizer.words(of: text) == expected)
    }

    /// A soft hyphen inside a line is a break opportunity, not a separator (review of #125, N3).
    @Test(arguments: [
        ("Steuer\u{00AD}bescheid", ["steuerbescheid"]),
        ("Grund\u{00AD}\u{00AD}steuer", ["grundsteuer"]),
        ("Kfz\u{00AD}Steuer", ["kfzsteuer"]),
        ("Über\u{00AD}weisung", ["uberweisung"]),
        ("Steuer\u{00AD} bescheid", ["steuer", "bescheid"]),
        ("Steuer\u{00AD}", ["steuer"]),
        ("\u{00AD}Steuer", ["steuer"]),
    ])
    func aSoftHyphenInsideAWordIsRemoved(text: String, expected: [String]) {
        #expect(SearchTokenizer.words(of: text) == expected)
    }

    @Test func aSoftHyphenInsideAQueryWordIsRemoved() {
        #expect(
            SearchTokenizer.terms(of: "steuer\u{00AD}bescheid").map(\.forms) == [["steuerbescheid", "steurbescheid"]])
    }

    /// The infix rule reads the length typed (review of #125, N2): "Mül" has 3 characters, its transcription
    /// `muel` 4.
    @Test func aTermAllowsInfixByItsTypedLength() {
        let short = SearchTokenizer.terms(of: "Mül")
        #expect(short.map(\.forms) == [["mul", "muel"]])
        #expect(short.map(\.allowsInfix) == [false])
        #expect(SearchTokenizer.terms(of: "Müll").map(\.allowsInfix) == [true])
        #expect(SearchTokenizer.terms(of: "θην θηνα").map(\.allowsInfix) == [false, true])
        #expect(SearchTokenizer.terms(of: "ung nung").map(\.allowsInfix) == [false, true])
    }

    @Test func aDecomposedAccentStaysInItsWord() {
        #expect(SearchTokenizer.words(of: "Cafe\u{301} Mu\u{308}ller") == ["cafe", "muller"])
    }

    @Test func mixedWordsGoThroughTheSlowPath() {
        #expect(
            SearchTokenizer.words(of: "STRAẞENBAHN Größe ﬁnanzamt Ｒｅｃｈｎｕｎｇ") == [
                "strassenbahn", "grosse", "finanzamt", "rechnung",
            ])
    }

    /// The ASCII fast path only lowercases; it must give exactly what normalising gives.
    @Test func fastPathAndSlowPathAgreeOnGeneratedASCIIWords() {
        var random = TestRandom(seed: 0x7121)
        let letters = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        for _ in 0..<2_000 {
            let word = String((0..<(1 + random.below(12))).map { _ in letters[random.below(letters.count)] })
            #expect(SearchTokenizer.words(of: word) == [SearchNormalizer.normalizedWord(word)], "\(word)")
        }
    }

    @Test func aQueryHasOneTermPerWordWithItsAlternatives() {
        let terms = SearchTokenizer.terms(of: "Müller mueller muller Rechnung")
        #expect(terms.map(\.forms) == [["muller", "mueller"], ["mueller", "muller"], ["muller"], ["rechnung"]])
    }

    @Test func aRepeatedTermCountsOnce() {
        #expect(SearchTokenizer.terms(of: "Steuer steuer STEUER").map(\.forms) == [["steuer", "steur"]])
    }

    @Test func aQueryOfPunctuationHasNoTerms() {
        #expect(SearchTokenizer.terms(of: " .,-/ ").isEmpty)
        #expect(SearchTokenizer.terms(of: "").isEmpty)
    }

    @Test func aQueryDoesNotJoinHyphens() {
        #expect(SearchTokenizer.terms(of: "steuer-\nbescheid").map(\.forms) == [["steuer", "steur"], ["bescheid"]])
    }
}

/// SplitMix64 for test inputs: the same sequence on every run and platform.
struct TestRandom {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }

    mutating func below(_ bound: Int) -> Int {
        Int(next() % UInt64(bound))
    }
}
