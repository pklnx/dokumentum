import DokumentumKit
import Foundation
import Testing

struct SearchIndexTests {
    static func id(_ number: Int) -> UUID {
        UUID(uuidString: String(format: "00000121-0000-4000-8000-%012d", number))!
    }

    private static func index(texts: [Int: String], merged: Bool = true) -> SearchIndex {
        var index = SearchIndex()
        for (number, text) in texts.sorted(by: { $0.key < $1.key }) { index.setText(text, for: id(number)) }
        if merged { index.mergeOverflow() }
        return index
    }

    private func numbers(_ ids: Set<UUID>) -> [Int] {
        ids.map { Int($0.uuidString.suffix(12))! }.sorted()
    }

    // MARK: Transcriptions (Revision 1, B1)

    /// Each spelling as a query finds each spelling in a text: 9 pinned pairs.
    @Test(arguments: ["Müller", "Mueller", "muller"], ["Müller", "Mueller", "muller"])
    func transcriptionsFindEachOtherInEveryDirection(query: String, text: String) {
        let index = Self.index(texts: [1: "Schreiben von Herrn \(text) vom 3. Mai", 2: "Schreiben von Frau Schmidt"])
        #expect(numbers(index.search(query)) == [1], "query \(query), text \(text)")
    }

    @Test func transcriptionsWorkBothWaysForOtherUmlauts() {
        let index = Self.index(texts: [1: "Köhler Gebäude", 2: "Koehler Gebaeude", 3: "Kohler Gebaude"])
        #expect(numbers(index.search("Köhler")) == [1, 2, 3])
        #expect(numbers(index.search("koehler")) == [1, 2, 3])
        #expect(numbers(index.search("Gebäude")) == [1, 2, 3])
    }

    @Test func strasseFindsStrasse() {
        let index = Self.index(texts: [1: "Hauptstraße 5", 2: "HAUPTSTRASSE 7", 3: "Hauptweg"])
        #expect(numbers(index.search("Straße")) == [1, 2])
        #expect(numbers(index.search("strasse")) == [1, 2])
    }

    // MARK: Prefix and infix (P1)

    @Test func shortTermsMatchOnlyTheStartOfAWord() {
        let index = Self.index(texts: [1: "Rechnung", 2: "Ungarn", 3: "Steuerbescheid"])
        #expect(numbers(index.search("ung")) == [2])
        #expect(numbers(index.search("r")) == [1])
        #expect(numbers(index.search("st")) == [3])
        #expect(numbers(index.search("bes")) == [])
    }

    @Test func termsOfFourOrMoreLettersAlsoMatchInsideAWord() {
        let index = Self.index(texts: [1: "Rechnung", 2: "Ungarn", 3: "Steuerbescheid", 4: "Grundsteuer"])
        #expect(numbers(index.search("bescheid")) == [3])
        #expect(numbers(index.search("steuer")) == [3, 4])
        #expect(numbers(index.search("nung")) == [1])
        #expect(numbers(index.search("rechnungen")) == [])
    }

    @Test func numbersAndCodesAreFoundByTheirParts() {
        let index = Self.index(texts: [1: "Datum 12.03.2024, Kunde ABC-123456", 2: "Datum 13.03.2023"])
        #expect(numbers(index.search("12.03.2024")) == [1])
        #expect(numbers(index.search("03")) == [1, 2])
        #expect(numbers(index.search("2345")) == [1])
        #expect(numbers(index.search("abc-123456")) == [1])
    }

    // MARK: AND across terms and fields

    @Test func everyTermMustMatchInAnyField() {
        var index = SearchIndex()
        index.setMetadata(
            SearchFields(title: "Steuerbescheid 2024", correspondent: "Finanzamt München"), for: Self.id(1))
        index.setText("Einkommensteuer für das Jahr", for: Self.id(1))
        index.setMetadata(SearchFields(title: "Rechnung", correspondent: "Finanzamt Köln"), for: Self.id(2))
        index.setText("Jahr 2024", for: Self.id(2))
        index.mergeOverflow()
        #expect(numbers(index.search("finanzamt")) == [1, 2])
        #expect(numbers(index.search("finanzamt münchen")) == [1])
        // "einkommen" only in the text, "münchen" only in the metadata.
        #expect(numbers(index.search("einkommen münchen")) == [1])
        #expect(numbers(index.search("2024 jahr")) == [1, 2])
        #expect(numbers(index.search("finanzamt köln einkommen")) == [])
        #expect(numbers(index.search("")) == [])
        #expect(numbers(index.search("  .  ")) == [])
    }

    @Test func tagPathsCorrespondentsAndTypesAreIndexed() {
        let steuer = UUID()
        let year = UUID()
        let tree = TagTree([
            TagRecord(instanceID: steuer, parentInstanceID: nil, name: "Steuer"),
            TagRecord(instanceID: year, parentInstanceID: steuer, name: "2024"),
        ])
        let gone = UUID()
        let document = LibraryDocument(
            instanceID: Self.id(1), title: "Scan", documentDate: .distantPast, createdAt: .distantPast,
            isInbox: false, correspondent: .init(instanceID: UUID(), name: "Stadtwerke"),
            documentType: .init(instanceID: UUID(), name: "Abrechnung"), tagIDs: [year, gone])
        let fields = SearchFields(document, tree: tree, unlistedTagNames: [gone: "Altlasten"])
        #expect(fields.tagPaths == ["Altlasten", "Steuer › 2024"])
        var index = SearchIndex()
        index.setMetadata(fields, for: Self.id(1))
        index.setMetadata(SearchFields(title: "Other"), for: Self.id(2))
        for query in ["steuer", "2024", "altlasten", "stadtwerke", "abrechnung", "scan"] {
            #expect(numbers(index.search(query)) == [1], "\(query)")
        }
    }

    @Test func aHyphenAtTheEndOfOneFieldDoesNotJoinTheNext() {
        var index = SearchIndex()
        index.setMetadata(SearchFields(title: "Kfz-", correspondent: "steuer"), for: Self.id(1))
        #expect(numbers(index.search("kfzsteuer")) == [])
        #expect(numbers(index.search("kfz steuer")) == [1])
    }

    // MARK: Updates

    @Test func setTextReplacesThePreviousText() {
        var index = Self.index(texts: [1: "Rechnung Strom", 2: "Strom"])
        index.setText("Mahnung Gas", for: Self.id(1))
        #expect(numbers(index.search("rechnung")) == [])
        #expect(numbers(index.search("strom")) == [2])
        #expect(numbers(index.search("mahnung")) == [1])
        index.setText("", for: Self.id(1))
        #expect(numbers(index.search("mahnung")) == [])
        #expect(index.contains(Self.id(1)))
    }

    @Test func aTokenInBothFieldsStaysUntilBothDropIt() {
        var index = SearchIndex()
        index.setMetadata(SearchFields(title: "Rechnung"), for: Self.id(1))
        index.setText("Rechnung Strom", for: Self.id(1))
        index.setText("Strom", for: Self.id(1))
        #expect(numbers(index.search("rechnung")) == [1])
        index.setMetadata(SearchFields(title: "Brief"), for: Self.id(1))
        #expect(numbers(index.search("rechnung")) == [])
        #expect(numbers(index.search("brief strom")) == [1])
    }

    @Test func setMetadataSkipsEqualFields() {
        var index = SearchIndex()
        let fields = SearchFields(title: "Rechnung", tagPaths: ["B", "A"])
        let first = index.setMetadata(fields, for: Self.id(1))
        let same = index.setMetadata(SearchFields(title: "Rechnung", tagPaths: ["A", "B"]), for: Self.id(1))
        #expect(first)
        #expect(!same)
        #expect(index.metadata(for: Self.id(1)) == fields)
        let changed = index.setMetadata(SearchFields(title: "Mahnung"), for: Self.id(1))
        #expect(changed)
        #expect(numbers(index.search("rechnung")) == [])
    }

    @Test func removeTakesEverythingAndTheSlotIsReused() {
        var index = Self.index(texts: [1: "Rechnung Strom", 2: "Rechnung Gas"])
        index.setMetadata(SearchFields(title: "Januar"), for: Self.id(1))
        index.remove(Self.id(1))
        index.remove(Self.id(99))
        #expect(numbers(index.search("rechnung")) == [2])
        #expect(numbers(index.search("strom")) == [])
        #expect(numbers(index.search("januar")) == [])
        #expect(index.documentIDs == [Self.id(2)])
        #expect(index.metadata(for: Self.id(1)) == nil)
        // Only document 2's rechnung and gas are left.
        #expect(index.statistics.postings == 2)
        // The freed slot goes to the next new document; given only metadata, it has none of the old text.
        index.setMetadata(SearchFields(title: "Wasser"), for: Self.id(3))
        #expect(numbers(index.search("wasser")) == [3])
        #expect(numbers(index.search("strom")) == [])
        #expect(numbers(index.search("rechnung")) == [2])
        #expect(index.statistics.documents == 2)
    }

    // MARK: Overflow and merge (T7)

    @Test func aDocumentAddedAfterTheMergeIsFoundBeforeTheNextMerge() {
        var index = Self.index(texts: [1: "Rechnung"])
        index.setText("Zahnarzt Quittung", for: Self.id(2))
        #expect(index.statistics.overflowTokens > 0)
        #expect(numbers(index.search("zahn")) == [2])
        #expect(numbers(index.search("arzt")) == [2])
        #expect(numbers(index.search("quittung")) == [2])
    }

    @Test func resultsAreTheSameBeforeAndAfterTheMerge() {
        let texts = [
            1: "Steuerbescheid Finanzamt München 2024", 2: "Rechnung Stadtwerke Strom Gas",
            3: "Mueller Köhler Straße", 4: "Grundsteuer Bescheid Gemeinde",
        ]
        let unmerged = Self.index(texts: texts, merged: false)
        let merged = Self.index(texts: texts, merged: true)
        #expect(unmerged.statistics.overflowTokens > 0)
        #expect(merged.statistics.overflowTokens == 0)
        for query in ["s", "st", "ste", "steuer", "bescheid", "müller", "koehler", "strasse", "2024", "gas", "xyz"] {
            #expect(unmerged.search(query) == merged.search(query), "\(query)")
        }
    }

    @Test func tokensWithoutPostingsAreDroppedAtTheMerge() {
        var index = Self.index(texts: [1: "Rechnung Strom", 2: "Strom"])
        #expect(index.statistics.tokens == 2)
        index.setText("Gas", for: Self.id(1))
        // rechnung has no postings now, but stays until the merge.
        #expect(index.statistics.tokens == 3)
        index.mergeOverflow()
        // rechnung is gone, gas is new.
        #expect(index.statistics.tokens == 2)
        #expect(index.statistics.postings == 2)
        #expect(numbers(index.search("r")) == [])
        index.setText("Rechnung", for: Self.id(1))
        #expect(numbers(index.search("rechnung")) == [1])
    }

    @Test func aTokenAddedAndTakenBackBeforeTheMergeIsDropped() {
        var index = Self.index(texts: [1: "Strom"])
        index.setText("Strom Zahnarzt", for: Self.id(1))
        index.setText("Strom", for: Self.id(1))
        #expect(index.statistics.overflowTokens == 1)
        index.mergeOverflow()
        #expect(index.statistics == .init(documents: 1, tokens: 1, postings: 1, overflowTokens: 0))
        #expect(numbers(index.search("zahn")) == [])
    }

    @Test func theIndexMergesByItselfWhenTheOverflowIsFull() {
        var index = SearchIndex(overflowLimit: 4)
        index.setText("eins zwei drei", for: Self.id(1))
        #expect(index.statistics.overflowTokens == 3)
        index.setText("vier fünf", for: Self.id(2))
        #expect(index.statistics.overflowTokens == 0)
        #expect(numbers(index.search("fünf")) == [2])
        #expect(numbers(index.search("drei")) == [1])
    }

    @Test func statisticsCountDistinctTokensAndPostings() {
        let index = Self.index(texts: [1: "Steuer Steuer Rechnung", 2: "Steuer"])
        // steuer, steur (its a/o/u form), rechnung.
        #expect(index.statistics == .init(documents: 2, tokens: 3, postings: 5, overflowTokens: 0))
    }
}
