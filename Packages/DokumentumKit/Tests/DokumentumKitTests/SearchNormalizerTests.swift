import DokumentumKit
import Testing

/// Pinned outputs: `kit-linux` runs them too, so a difference between Apple's and Linux Foundation fails CI
/// instead of shipping (plan of #7, T4).
struct SearchNormalizerTests {
    @Test(arguments: [
        ("Straße", "strasse"),
        ("STRASSE", "strasse"),
        ("ẞ", "ss"),
        ("ß", "ss"),
        ("MÜLLER", "muller"),
        ("Müller", "muller"),
        ("ﬁnanzamt", "finanzamt"),
        ("Ｒｅｃｈｎｕｎｇ", "rechnung"),
        ("école", "ecole"),
        ("e\u{301}cole", "ecole"),
        ("Œuvre", "oeuvre"),
        ("Æble", "aeble"),
        ("Øresund", "oresund"),
        ("Łódź", "lodz"),
        ("Đaković", "dakovic"),
        ("Þórr", "thorr"),
        ("Kündigung", "kundigung"),
        ("²", "2"),
        ("㎏", "kg"),
    ])
    func wordsNormalizeTo(word: String, expected: String) {
        #expect(SearchNormalizer.normalizedWord(word) == expected)
    }

    /// Review N7: the outputs with `locale: nil`, pinned instead of runs under a Turkish locale.
    @Test(arguments: [("\u{130}", "i"), ("I", "i"), ("i", "i"), ("\u{131}", "\u{131}")])
    func turkishIsArePinned(word: String, expected: String) {
        #expect(Array(SearchNormalizer.normalizedWord(word).unicodeScalars) == Array(expected.unicodeScalars))
    }

    @Test func composedAndDecomposedFormsAreTheSameBytes() {
        let composed = SearchNormalizer.normalizedWord("Ångström")
        let decomposed = SearchNormalizer.normalizedWord("A\u{30A}ngstro\u{308}m")
        #expect(Array(composed.utf8) == Array(decomposed.utf8))
        #expect(composed == "angstrom")
    }

    @Test func aCompatibilityFormCanContainASeparator() {
        // NFKC turns "½" into "1⁄2"; the tokeniser splits it again.
        #expect(SearchNormalizer.normalizedWord("½") == "1\u{2044}2")
        #expect(SearchTokenizer.words(of: "½") == ["1", "2"])
    }

    @Test(arguments: [
        ("mueller", "muller"),
        ("steuer", "steur"),
        ("koehler", "kohler"),
        ("schaefer", "schafer"),
        ("queue", "quu"),
        ("aee", "ae"),
    ])
    func detranscriptionReadsAeOeUeAsUmlauts(token: String, expected: String) {
        #expect(SearchNormalizer.detranscribed(token) == expected)
    }

    @Test func aTokenWithoutTranscriptionHasNoDetranscribedForm() {
        #expect(SearchNormalizer.detranscribed("muller") == nil)
        #expect(SearchNormalizer.detranscribed("rechnung") == nil)
        #expect(SearchNormalizer.detranscribed("e") == nil)
    }

    @Test func transcriptionWritesUmlautsOut() {
        #expect(SearchNormalizer.transcribed("Müller") == "Mueller")
        #expect(SearchNormalizer.transcribed("ÄÖÜ") == "AeOeUe")
        #expect(SearchNormalizer.transcribed("Mu\u{308}ller") == "Mueller")
        #expect(SearchNormalizer.transcribed("Straße") == nil)
    }

    @Test func theCacheNormalizesEachRawWordOnce() {
        var cache = SearchNormalizer.Cache()
        #expect(
            SearchTokenizer.words(of: "Müller Müller Straße müller", cache: &cache) == [
                "muller", "muller", "strasse", "muller",
            ])
        #expect(cache.count == 3)
        cache.removeAll()
        #expect(cache.count == 0)
    }
}
