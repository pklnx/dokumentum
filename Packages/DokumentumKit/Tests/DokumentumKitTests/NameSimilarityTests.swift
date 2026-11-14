import DokumentumKit
import Testing

/// Near-equal names (review B4 and B5 of #209): an OCR misread of a small line, and nothing else. The boundaries of
/// the per-word edit allowance: 0 up to 3 characters, 1 for 4–7, 2 from 8.
struct NameSimilarityTests {
    @Test(arguments: [
        ("Finanzamt Musterstadt", "Finanzamt Musterstact"),  // macOS 27.2's read
        ("Finanzamt Musterstadt", "Finanzamt Mustorstact"),  // the iOS 27.0 simulator's read: 2 edits, 11 letters
        ("Stadtbibliothek Musterstadt", "Stadtbibiothek Musterstadt"),
        ("Stadtbibliothek Musterstadt", "Stadtbibliothek Musterstad!"),  // `!` is no letter: `musterstad`
        ("Muster GmbH", "Mustar GmbH"),  // 1 edit in a 6-letter word
        ("Beispiel AG", "beispiel ag"),  // folded
        ("Müller Bau", "Muller Bau"),
    ])
    func nearEqual(_ pair: (String, String)) {
        #expect(NameSimilarity.isNearEqual(pair.0, pair.1), "\(pair)")
        #expect(NameSimilarity.isNearEqual(pair.1, pair.0), "symmetric: \(pair)")
    }

    @Test(arguments: [
        ("Finanzamt Musterstadt", "Finanzamt Mustxrstxcx"),  // 3 edits in an 11-letter word
        ("Muster GmbH", "Mxstxr GmbH"),  // 2 edits in a 6-letter word
        ("Muster AG", "Muster SE"),  // a 2-letter word must be equal
        ("Inkasso Beispiel GmbH", "Stadtwerke Musterstadt GmbH"),
        ("Finanzamt Musterstadt", "Finanzamt Musterstadt Nord"),  // another word count
        ("Stadtwerke Musterstadt GmbH", "Stadtwerke Musterstadt"),
        ("", ""),
    ])
    func notNearEqual(_ pair: (String, String)) {
        #expect(!NameSimilarity.isNearEqual(pair.0, pair.1), "\(pair)")
    }

    @Test func theAllowanceByLength() {
        #expect(NameSimilarity.allowedEdits(forLength: 3) == 0)
        #expect(NameSimilarity.allowedEdits(forLength: 4) == 1)
        #expect(NameSimilarity.allowedEdits(forLength: 7) == 1)
        #expect(NameSimilarity.allowedEdits(forLength: 8) == 2)
    }
}
