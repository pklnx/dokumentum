import DokumentumKit
import Foundation
import Testing

/// The sender from a page's layout (#11, part 1; plan Approach 3, review B1, B2, re-review R1-B1, N-r2 to N-r4).
/// Layouts are written in millimetres on A4 unless a case says otherwise.
struct SenderDetectorTests {
    typealias L = SyntheticLetter.Line

    static let owner = "Max Mustermann"
    /// A form A recipient block below a return-address line at 29 mm.
    static let recipient: [L] = [
        L("Herrn", x: 25, top: 35, size: 11), L("Max Mustermann", x: 25, top: 40, size: 11),
        L("Musterweg 2", x: 25, top: 45, size: 11), L("80331 München", x: 25, top: 50, size: 11),
    ]

    static func records(_ names: [String]) -> [MetadataMatcher.Record] {
        names.enumerated().map { index, name in
            MetadataMatcher.Record(
                id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index + 1)) ?? UUID(),
                name: name)
        }
    }

    private func detect(
        _ lines: [L], known: [String] = [owner], width: Double = 210, height: Double = 297
    ) -> DetectedSender? {
        SenderDetector.detect(
            in: SyntheticLetters.layout(lines, width: width, height: height), known: Self.records(known))
    }

    private func returnLine(_ text: String, size: Double = 7) -> [L] {
        [L(text, x: 25, top: 29, size: size)] + Self.recipient
    }

    /// The detected name, marked as known or structural.
    private func describe(_ sender: DetectedSender?) -> String {
        switch sender {
        case .existing(_, let name): "known \(name)"
        case .name(let name): "structural \(name)"
        case nil: "none"
        }
    }

    // MARK: The return-address line

    @Test func theReturnAddressLineGivesItsFirstSegment() {
        let lines = returnLine("Stadtwerke Musterstadt GmbH · Postfach 12 34 · 80287 Musterstadt")
        #expect(detect(lines) == .name("Stadtwerke Musterstadt GmbH"))
        #expect(
            detect(returnLine("Beispiel Hausverwaltung, Lindenstraße 4, 80333 München"))
                == .name("Beispiel Hausverwaltung"))
        #expect(detect(returnLine("Acme Ltd | 1 High Street | Oxford OX1 1AA")) == .name("Acme Ltd"))
        #expect(
            detect(returnLine("Northwind Health • 45 Oak Avenue • Portland, OR 97201")) == .name("Northwind Health"))
    }

    @Test func aStreetAPostBoxOrAPostcodeFirstIsNoName() {
        // The letterhead then decides; here it has no legal form, so nothing is found.
        let letterhead = L("Stadtwerke Musterstadt", x: 125, top: 12, size: 16)
        #expect(detect([letterhead] + returnLine("Werkstraße 1 · 80287 Musterstadt")) == nil, "a street")
        #expect(detect([letterhead] + returnLine("45 Oak Avenue, Portland, OR 97201")) == nil, "a number first")
        #expect(detect([letterhead] + returnLine("Postfach 12 34 · 80287 Musterstadt")) == nil, "a post box")
        let postcodeFirst = returnLine("Stadtwerke 80287 Musterstadt · Werkstraße 1 · 80287 Musterstadt")
        #expect(detect([letterhead] + postcodeFirst) == nil, "a postcode in the first segment")
        let withCompany =
            [L("Stadtwerke Musterstadt GmbH", x: 125, top: 12, size: 16)]
            + returnLine("Werkstraße 1 · 80287 Musterstadt")
        #expect(detect(withCompany) == .name("Stadtwerke Musterstadt GmbH"), "the letterhead decides")
    }

    @Test func aFirmNameWithACommaStaysWholeWhenTheLineHasADot() {
        // N4: `·` present, so commas do not split.
        let lines = returnLine("Müller, Schmidt & Partner Rechtsanwälte PartG mbB · Kanzleistraße 1 · 80333 München")
        #expect(detect(lines) == .name("Müller, Schmidt & Partner Rechtsanwälte PartG mbB"))
    }

    @Test func theReturnAddressLineMustBeTheTopmostFieldLine() {
        let line = L("Stadtwerke Musterstadt GmbH · Postfach 12 34 · 80287 Musterstadt", x: 25, top: 31, size: 7)
        let above = L("Kundenservice", x: 25, top: 27, size: 11)
        #expect(detect([line] + Self.recipient) == .name("Stadtwerke Musterstadt GmbH"))
        #expect(detect([above, line] + Self.recipient) == nil, "a field line above it")
        let rightOfTheField = L("Kundenservice", x: 125, top: 27, size: 11)
        #expect(detect([rightOfTheField, line] + Self.recipient) == .name("Stadtwerke Musterstadt GmbH"))
    }

    @Test func theReturnAddressLineMustLieInAReturnAddressZone() {
        func at(_ top: Double) -> [L] {
            [L("Stadtwerke Musterstadt GmbH · Postfach 12 34 · 80287 Musterstadt", x: 25, top: top, size: 7)]
                + Self.recipient.map { L($0.text, x: $0.x, top: $0.top + top - 29, size: $0.size) }
        }
        #expect(detect(at(24)) != nil, "form A, 3 mm above the zone")
        #expect(detect(at(35)) != nil, "form A, at the zone's bottom with the tolerance")
        #expect(detect(at(38)) == nil, "between the forms")
        #expect(detect(at(46)) != nil, "form B")
        #expect(detect(at(55)) == nil, "below form B's zone")
    }

    @Test func theReturnAddressLineNeedsItsSignal() {
        let text = "Stadtwerke Musterstadt GmbH · Postfach 12 34 · 80287 Musterstadt"
        #expect(detect(returnLine(text, size: 11)) == nil, "as large as the lines below it")
        #expect(detect(returnLine(text, size: 8.5)) == .name("Stadtwerke Musterstadt GmbH"), "below 0.8 × 11 pt")
        #expect(detect(returnLine(text, size: 9)) == nil, "above 0.8 × 11 pt")
        let oneBelow = [L(text, x: 25, top: 29, size: 7), L("Max Mustermann", x: 25, top: 40, size: 11)]
        #expect(detect(oneBelow) == nil, "only one field line below it")
        #expect(detect(returnLine("Stadtwerke Musterstadt GmbH · Postfach 12 34")) == nil, "no postcode")
        #expect(detect(returnLine("Stadtwerke Musterstadt GmbH")) == nil, "one segment")
    }

    // MARK: Known names

    @Test func aKnownNameInTheLetterheadOrFooterIsFound() {
        let known = [Self.owner, "Muster Versicherung"]
        let letterhead = [L("Muster Versicherung", x: 125, top: 12, size: 16)] + Self.recipient
        #expect(
            detect(letterhead, known: known) == .existing(id: Self.records(known)[1].id, name: "Muster Versicherung"))
        let footer = Self.recipient + [L("Muster Versicherung · Versicherungsplatz 1", x: 25, top: 280, size: 7)]
        #expect(detect(footer, known: known) == .existing(id: Self.records(known)[1].id, name: "Muster Versicherung"))
        let folded = [L("MUSTER VERSICHERUNG", x: 125, top: 12, size: 16)] + Self.recipient
        #expect(describe(detect(folded, known: known)) == "known Muster Versicherung", "case folded")
        let partOfAWord = [L("Muster Versicherungen", x: 125, top: 12, size: 16)] + Self.recipient
        #expect(detect(partOfAWord, known: known) == nil, "whole words only")
    }

    @Test func aKnownNameBeatsAStructuralNameInTheSameZone() {
        let lines = [L("Muster Versicherung AG", x: 125, top: 12, size: 16)] + Self.recipient
        #expect(describe(detect(lines, known: [Self.owner, "Muster Versicherung"])) == "known Muster Versicherung")
        #expect(describe(detect(lines)) == "structural Muster Versicherung AG")
    }

    @Test func theLongerKnownNameWins() {
        let lines = [L("Stadtwerke München", x: 125, top: 12, size: 16)] + Self.recipient
        let known = [Self.owner, "Stadtwerke", "Stadtwerke München"]
        #expect(describe(detect(lines, known: known)) == "known Stadtwerke München")
    }

    @Test func twoKnownNamesGiveNoneForTheDocument() {
        let lines =
            [
                L("Muster Versicherung", x: 125, top: 12, size: 16), L("Beispiel Bank", x: 125, top: 18, size: 9),
                L("Muster Versicherung AG", x: 25, top: 280, size: 7),
            ] + Self.recipient
        #expect(detect(lines, known: [Self.owner, "Muster Versicherung", "Beispiel Bank"]) == nil, "no fallback")
    }

    @Test func aKnownNameInTheReturnAddressLineIsFound() {
        let lines = returnLine("Stadtwerke Musterstadt GmbH · Postfach 12 34 · 80287 Musterstadt")
        let known = [Self.owner, "Stadtwerke Musterstadt"]
        #expect(describe(detect(lines, known: known)) == "known Stadtwerke Musterstadt")
    }

    // MARK: The recipient

    @Test func theRecipientIsNeverTheSender() {
        // The owner's name also stands in the letterhead: it is excluded everywhere.
        let lines = [L("Max Mustermann", x: 125, top: 12, size: 9)] + Self.recipient
        #expect(detect(lines) == nil)
        let ownerCompany = [L("Max Mustermann GmbH", x: 125, top: 12, size: 9)] + Self.recipient
        #expect(detect(ownerCompany, known: []) == .name("Max Mustermann GmbH"), "contains the recipient, not in it")
        let inRecipient =
            [L("Muster GmbH", x: 125, top: 12, size: 9), L("Muster GmbH", x: 25, top: 40, size: 11)]
            + Self.recipient.dropFirst(2)
        #expect(detect(inRecipient, known: []) == nil, "a structural name in a recipient line")
    }

    @Test(arguments: SenderDetector.recipientLabels)
    func aRecipientLabelledLineIsExcluded(label: String) {
        // The owner's name only in the info-block column, after a recipient label.
        let lines = [
            L("Muster Versand GmbH", x: 25, top: 12, size: 16), L("\(label): Max Mustermann", x: 125, top: 40, size: 9),
        ]
        #expect(detect(lines) == .name("Muster Versand GmbH"), "\(label)")
    }

    @Test func aLabelAloneCoversItsColumnBlockDownToAGap() {
        let lines = [
            L("Contoso Supplies LLC", x: 21.6, top: 14, size: 14), L("Ship To:", x: 130, top: 40, size: 10),
            L("John Smith", x: 130, top: 45, size: 10), L("45 Oak Avenue", x: 130, top: 49.5, size: 10),
        ]
        #expect(detect(lines, known: ["John Smith"]) == .name("Contoso Supplies LLC"))
        // After a gap of more than 1.5 line heights the block ends: the name there is in the letterhead again.
        let afterAGap = lines + [L("Max Mustermann", x: 130, top: 60, size: 10)]
        #expect(describe(detect(afterAGap, known: ["John Smith", "Max Mustermann"])) == "known Max Mustermann")
    }

    // MARK: The footer

    @Test func aFooterColumnBlockWithABankOrRegisterCueIsDroppedWhole() {
        for cue in SenderDetector.footerCues {
            let lines = [
                L("Max Mustermann", x: 21, top: 50, size: 11), L(cue, x: 136, top: 273, size: 7),
                L("Beispielbank AG", x: 136, top: 277.5, size: 7),
            ]
            #expect(detect(lines) == nil, "\(cue)")
        }
        let separateBlock = [
            L("Max Mustermann", x: 21, top: 50, size: 11), L("Muster Versand GmbH", x: 21, top: 273, size: 7),
            L("Bankverbindung", x: 136, top: 273, size: 7), L("Beispielbank AG", x: 136, top: 277.5, size: 7),
        ]
        #expect(detect(separateBlock) == .name("Muster Versand GmbH"))
        let afterAGap = [
            L("Max Mustermann", x: 21, top: 50, size: 11), L("Bankverbindung", x: 136, top: 260, size: 7),
            L("Beispielbank AG", x: 136, top: 280, size: 7),
        ]
        #expect(detect(afterAGap) == .name("Beispielbank AG"), "a gap of more than 1.5 line heights ends the block")
    }

    // MARK: Structural names

    @Test(arguments: [
        ("Muster GmbH & Co. KG", "Muster GmbH & Co. KG"),
        ("Beispiel UG (haftungsbeschränkt)", "Beispiel UG (haftungsbeschränkt)"),
        ("Sportverein Musterstadt e.V.", "Sportverein Musterstadt e.V."),
        ("Winzer Musterdorf eG", "Winzer Musterdorf eG"),
        ("Blumen Beispiel e.K.", "Blumen Beispiel e.K."), ("Muster Holding SE", "Muster Holding SE"),
        ("Beispiel KGaA", "Beispiel KGaA"), ("Muster & Söhne OHG", "Muster & Söhne OHG"),
        ("Praxis Beispiel GbR", "Praxis Beispiel GbR"),
        ("Muster Pflege gGmbH", "Muster Pflege gGmbH"),
        ("Muster Vertriebsgesellschaft mbH", "Muster Vertriebsgesellschaft mbH"),
        ("Beispiel Partner PartG", "Beispiel Partner PartG"), ("Muster AG", "Muster AG"), ("Muster KG", "Muster KG"),
        ("Acme Widgets Ltd.", "Acme Widgets Ltd"), ("Acme Widgets Limited", "Acme Widgets Limited"),
        ("Contoso LLC", "Contoso LLC"), ("Fabrikam Inc.", "Fabrikam Inc."), ("Fabrikam, Inc.", "Fabrikam, Inc."),
        ("Litware Corp.", "Litware Corp."), ("Wingtip Holdings PLC", "Wingtip Holdings PLC"),
        ("Beispiel Partners LLP", "Beispiel Partners LLP"),
        ("© 2026 Muster GmbH. Alle Rechte vorbehalten.", "Muster GmbH"), ("© 2020–2026 Muster AG", "Muster AG"),
        ("Muster Versand GmbH · Hafenstraße 9 · 20457 Hamburg", "Muster Versand GmbH"),
    ])
    func aLegalFormGivesTheCompanyName(line: String, name: String) {
        #expect(detect([L(line, x: 25, top: 12, size: 12)] + Self.recipient) == .name(name), "\(line)")
    }

    @Test func noLegalFormOrNoNameGivesNone() {
        #expect(detect([L("Muster Versand", x: 25, top: 12, size: 16)] + Self.recipient) == nil)
        #expect(detect([L("AG", x: 25, top: 12, size: 16)] + Self.recipient) == nil, "a legal form alone")
        #expect(detect([L("© 2026 GmbH", x: 25, top: 12, size: 16)] + Self.recipient) == nil)
        let long = "Eins Zwei Drei Vier Fünf Sechs Sieben Acht GmbH"
        #expect(detect([L(long, x: 25, top: 12, size: 12)] + Self.recipient) == nil, "nine words")
        let wide = String(repeating: "Muster", count: 14) + " GmbH"
        #expect(detect([L(wide, x: 25, top: 12, size: 12)] + Self.recipient) == nil, "89 characters")
        #expect(detect(Self.recipient) == nil)
        #expect(detect([]) == nil)
    }

    @Test func theTopmostLetterheadCompanyWins() {
        let lines =
            [
                L("Zweite Beispiel AG", x: 125, top: 20, size: 9), L("Erste Muster GmbH", x: 25, top: 12, size: 16),
            ] + Self.recipient
        #expect(detect(lines) == .name("Erste Muster GmbH"))
    }

    // MARK: Review cases and page sizes

    /// The review's S1–S9 (6863747860): none of S1–S8 yields the recipient, the bank or the court.
    @Test(arguments: [
        ("S1-us-portland", "known Northwind Dental Care"),
        ("S1b-us-city-in-zone", "known Northwind Dental Care"),
        ("S2b-uk-town-in-zone", "structural Brightwater Opticians Ltd"),
        ("S2-uk-manchester", "structural Brightwater Opticians Ltd"),
        ("S3-shop-delivery", "structural Muster Shop GmbH"),
        ("S4-insurer-info-block", "structural Muster Versicherung AG"),
        ("S5-us-invoice-ship-to", "structural Fabrikam, Inc."),
        ("S6-footer-bank-known", "known Praxis Dr. med. Hans Beispiel"),
        ("S7-footer-bank-unknown", "none"), ("S8-footer-court-known", "known Kanzlei Beispiel Rechtsanwälte"),
        ("din-a-stadtwerke", "structural Stadtwerke Musterstadt GmbH"),
        ("S3a-receipt", "structural Muster Shop GmbH"), ("S3b-body-below", "structural Muster Shop GmbH"),
        ("S3c-labelled", "structural Muster Shop GmbH"), ("S3c-info-block", "structural Muster Shop GmbH"),
        ("ship-to-only", "structural Contoso Supplies LLC"), ("din-b-letterhead-40", "known Muster Versicherung AG"),
        ("din-b-letterhead-no-return", "none"),
    ])
    func reviewCase(id: String, expected: String) throws {
        let letter = try #require(SyntheticLetters.letter(id))
        let found = SenderDetector.detect(in: letter.layout, known: Self.records(letter.knownNames))
        #expect(describe(found) == expected, "\(id)")
        for name in [
            letter.recipient, "Commerzbank AG", "Stadtsparkasse München", "Amtsgericht München", "Portland",
            "Manchester",
        ] {
            #expect(!describe(found).hasSuffix(" \(name)"), "\(id): \(name)")
        }
    }

    @Test(arguments: ["din-b-stadtbibliothek", "din-b-us-letter", "din-b-us-legal", "din-b-odd-size"])
    func theSameLetterOnAnyPageSize(id: String) throws {
        let letter = try #require(SyntheticLetters.letter(id))
        let found = SenderDetector.detect(in: letter.layout, known: Self.records(letter.knownNames))
        #expect(found == .name("Stadtbibliothek Musterstadt"), "\(id)")
    }
}
