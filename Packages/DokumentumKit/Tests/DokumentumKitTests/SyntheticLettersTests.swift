import DokumentumKit
import Foundation
import Testing

/// The `SyntheticLetters` corpus as layouts (#11, part 1; plan Tests part 1): every letter, evaluated with its
/// recipient among the known correspondents (B1.5), gives its expected sender and date.
struct SyntheticLettersTests {
    @Test func theCorpusHasEveryFixtureOfThePlan() {
        let ids = Set(SyntheticLetters.all.map(\.id))
        #expect(SyntheticLetters.all.count >= 20)
        #expect(ids.count == SyntheticLetters.all.count, "unique ids")
        let required = [
            "din-a-stadtwerke", "din-b-stadtbibliothek", "din-b-letterhead-40", "din-b-letterhead-no-return",
            "finanzamt", "rechnung-zeitraum", "muenchen-den", "versicherung-geburtsdatum", "probe2-bank-known",
            "probe2-bank-unknown", "S1-us-portland", "S1b-us-city-in-zone", "S2-uk-manchester", "S2b-uk-town-in-zone",
            "S3-shop-delivery", "S3a-receipt",
            "S3b-body-below", "S3c-labelled", "S4-insurer-info-block", "S5-us-invoice-ship-to", "ship-to-only",
            "law-firm", "uk-acme", "us-invoice", "us-letter-slash", "future-year", "nothing", "din-b-us-letter",
            "din-b-us-legal", "din-b-odd-size", "swiss-right-window-125", "swiss-right-window-130",
            "swiss-left-references", "swiss-left-date",
            "us-letterhead-springfield", "us-legal-letterhead-springfield", "uk-letterhead-oxford",
            "din-a-small-recipient", "uk-small-recipient", "us-half-inch-margin", "finanzamt-known-misread-return-line",
            "inkasso-creditor-info-block", "inkasso-on-behalf-info-block",
            "inkasso-partner-letterhead", "footer-known-parent-return-line", "near-known-not-on-the-page",
            "two-near-known-in-the-letterhead", "correct-return-line-in-the-letterhead",
            "truncated-misread-return-line",
        ]
        for id in required { #expect(ids.contains(id), "\(id)") }
    }

    @Test(arguments: SyntheticLetters.all.map(\.id))
    func aLetterGivesItsSenderAndDate(id: String) throws {
        let letter = try #require(SyntheticLetters.letter(id))
        let records = SenderDetectorTests.records(letter.knownNames)
        let sender = SenderDetector.detect(in: letter.layout, known: records)
        switch letter.sender {
        case .known(let name):
            let record = try #require(records.first { $0.name == name })
            #expect(sender == .existing(id: record.id, name: name), "\(id)")
        case .structural(let name):
            #expect(sender == .name(name), "\(id)")
        case .none:
            #expect(sender == nil, "\(id)")
        }
        if case .existing(_, let name) = sender { #expect(name != letter.recipient, "\(id): never the recipient") }
        let date = IssueDateDetector.detect(in: letter.text, createdAt: letter.createdAt)
        #expect(date == letter.date, "\(id)")
    }

    @Test func theLayoutKeepsTheMillimetres() throws {
        let letter = try #require(SyntheticLetters.letter("din-b-us-legal"))
        let layout = letter.layout
        #expect(abs(layout.width - 612) < 0.01)
        #expect(abs(layout.height - 1008) < 0.01)
        let geometry = layout.geometry
        #expect(geometry.isStandardSize)
        let returnLine = try #require(layout.lines.first { $0.text.hasPrefix("Stadtbibliothek Musterstadt ·") })
        #expect(abs(returnLine.box.y * geometry.height - 46) < 0.001)
        #expect(abs(returnLine.box.x * geometry.width - 25) < 0.001)
    }

    @Test func theTextIsTopToBottomThenLeftToRight() throws {
        let letter = try #require(SyntheticLetters.letter("probe2-bank-known"))
        let lines = letter.text.split(separator: "\n").map(String.init)
        #expect(lines.prefix(4) == ["Muster Versand", "Max Mustermann", "Kundennummer: 4711", "Musterweg 2"])
    }
}
