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

    /// Written out, not taken from `SenderDetector.recipientLabels`, so that a label dropped from the list fails here.
    @Test(arguments: [
        "Kunde", "Kundin", "Kundenname", "Name", "Versicherungsnehmer", "Versicherungsnehmerin", "Versicherte Person",
        "Patient", "Patientin", "Mandant", "Mandantin", "Empfänger", "Empfängerin", "Rechnungsempfänger",
        "Rechnungsempfängerin", "Leistungsempfänger", "Leistungsempfängerin", "Warenempfänger", "Warenempfängerin",
        "Kontoinhaber", "Kontoinhaberin", "Anschrift", "Lieferadresse", "Rechnungsadresse", "Rechnungsanschrift",
        "Lieferanschrift", "Rechnung an", "Lieferung an", "Bill to", "Bill-to", "Ship to", "Ship-to", "Sold to",
        "Deliver to", "Invoice to", "Billing Address", "Shipping Address", "Invoice Address", "Delivery Address",
        "Customer", "Account holder", "Policyholder",
    ])
    func aRecipientLabelledLineIsExcluded(label: String) {
        // The owner's name only in the info-block column, after a recipient label; the field names the family, so the
        // owner's exact name stands in no recipient line (review A2 of #204).
        let lines = [
            L("Muster Versand GmbH", x: 25, top: 12, size: 16), L("Familie Mustermann", x: 25, top: 44.5, size: 11),
            L("Musterweg 2", x: 25, top: 49, size: 11), L("80331 München", x: 25, top: 53.5, size: 11),
            L("\(label): Max Mustermann", x: 125, top: 45, size: 9),
        ]
        #expect(detect(lines) == .name("Muster Versand GmbH"), "\(label)")
    }

    @Test func aLabelAloneCoversItsColumnBlockDownToAGap() {
        let lines = [
            L("Contoso Supplies LLC", x: 21.6, top: 14, size: 14), L("Packing Slip", x: 21.6, top: 40, size: 14),
            L("Warehouse: Springfield, IL 62701", x: 21.6, top: 48, size: 10), L("Ship To:", x: 130, top: 40, size: 10),
            L("John Smith", x: 130, top: 45, size: 10),
            L("45 Oak Avenue", x: 130, top: 49.5, size: 10),
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

    // MARK: Fix round 1 of #204

    @Test func aRightWindowRecipientBlockIsExcluded() {
        // B1: nothing in the left field, the recipient block in a right window, the owner known.
        for x in [118.0, 125, 130] {
            let block = [
                L("Herr", x: x, top: 53, size: 11), L("Max Mustermann", x: x, top: 58, size: 11),
                L("Seestrasse 5", x: x, top: 63, size: 11), L("8002 Zürich", x: x, top: 68, size: 11),
            ]
            #expect(detect([L("Muster", x: 20, top: 15, size: 20)] + block) == nil, "\(x)")
            #expect(detect([L("Muster AG", x: 20, top: 15, size: 20)] + block) == .name("Muster AG"), "\(x)")
            let withReturnLine = [L("Muster AG, Bahnhofstrasse 1, 8001 Zürich", x: x, top: 48, size: 7)] + block
            #expect(detect([L("Muster", x: 20, top: 15, size: 20)] + withReturnLine) == .name("Muster AG"), "\(x)")
        }
        // Both blocks on the right with label-only lines (review A3 of #204).
        let invoice = [
            L("Contoso Supplies LLC", x: 20, top: 12, size: 16), L("BILLING ADDRESS", x: 125, top: 40, size: 9),
            L("John Smith", x: 125, top: 44, size: 9), L("SHIPPING ADDRESS", x: 165, top: 40, size: 9),
            L("John Smith", x: 165, top: 44, size: 9), L("INVOICE 1001", x: 20, top: 95, size: 14),
        ]
        #expect(detect(invoice, known: ["John Smith"], width: 215.9, height: 279.4) == .name("Contoso Supplies LLC"))
    }

    @Test func aTownBeforeAPostcodeIsNoName() {
        // B2: the return-address line's first segment is a town when the next segment is only a postcode.
        let letterhead = L("Contoso Supplies", x: 25, top: 12, size: 18)
        #expect(detect([letterhead] + returnLine("Springfield, IL 62701")) == nil)
        #expect(detect([letterhead] + returnLine("Oxford, OX1 1AA")) == nil)
        #expect(detect([letterhead] + returnLine("Musterstadt, 80284")) == nil)
        #expect(
            detect([letterhead] + returnLine("Finanzamt Musterstadt · 80284 Musterstadt"))
                == .name("Finanzamt Musterstadt"))
        #expect(detect([letterhead] + returnLine("Acme Ltd, 1 High Street, Oxford OX1 1AA")) == .name("Acme Ltd"))
    }

    @Test func theSmallerReturnAddressLineWinsWhenBothFormsHaveOne() {
        // N3: form A's line (7 pt) and a recipient line (9 pt) in form B's zone that qualifies too.
        let lines = [
            L("Muster Versicherung AG · Postfach 1 · 80001 München", x: 25, top: 28, size: 7),
            L("Herrn Max Mustermann", x: 25, top: 36, size: 9),
            L("Muster Bank AG, Musterweg 2, 80331 München", x: 25, top: 43, size: 9),
            L("Ihre Police", x: 25, top: 60, size: 12), L("Sehr geehrter Herr Mustermann,", x: 25, top: 70, size: 12),
        ]
        #expect(detect(lines) == .name("Muster Versicherung AG"), "form A's smaller line")
        // A tie goes to form B.
        let tie = [
            L("Muster AG · Musterplatz 1 · 80001 München", x: 25, top: 26, size: 7),
            L("Beispiel AG · Postfach 9 · 80002 München", x: 25, top: 46, size: 7),
            L("Herrn", x: 25, top: 52, size: 11), L("Max Mustermann", x: 25, top: 57, size: 11),
            L("Musterweg 2", x: 25, top: 62, size: 11),
        ]
        #expect(detect(tie) == .name("Beispiel AG"))
    }

    @Test func moreFooterCues() {
        // N2: a bank column with only an IBAN, `BLZ`/`Kto.`, and `Geschäftsführung`.
        let head = [L("Muster Versand", x: 25, top: 15, size: 16)] + Self.recipient
        let company = [
            L("Muster Versand GmbH", x: 20, top: 273, size: 7), L("Musterstraße 1", x: 20, top: 277.5, size: 7),
        ]
        let known = [Self.owner, "Stadtsparkasse München"]
        let iban = [
            L("Stadtsparkasse München", x: 148, top: 273, size: 7),
            L("DE12 7015 0000 0012 3456 78", x: 148, top: 277.5, size: 7), L("SSKMDEMMXXX", x: 148, top: 282, size: 7),
        ]
        #expect(detect(head + company + iban, known: known) == .name("Muster Versand GmbH"), "an IBAN alone")
        let compact = [
            L("Stadtsparkasse München", x: 148, top: 273, size: 7),
            L("DE12701500000012345678", x: 148, top: 277.5, size: 7),
        ]
        #expect(detect(head + company + compact, known: known) == .name("Muster Versand GmbH"), "an IBAN in one run")
        let oldStyle = [
            L("Stadtsparkasse München", x: 148, top: 273, size: 7), L("BLZ 701 500 00", x: 148, top: 277.5, size: 7),
            L("Kto. 123 456", x: 148, top: 282, size: 7),
        ]
        #expect(detect(head + company + oldStyle, known: known) == .name("Muster Versand GmbH"), "BLZ, Kto.")
        let management = [
            L("Geschäftsführung: Erika Beispiel", x: 82, top: 273, size: 7),
            L("Muster Holding GmbH", x: 82, top: 277.5, size: 7),
        ]
        #expect(detect(head + management) == nil, "Geschäftsführung")
        let phone = [
            L("Muster Versand GmbH", x: 20, top: 273, size: 7), L("Tel. 0123 456789", x: 20, top: 277.5, size: 7),
        ]
        #expect(detect(head + phone) == .name("Muster Versand GmbH"), "a phone number is no IBAN")
    }

    @Test func aSentenceOrTwoJoinedNamesAreNoName() {
        // N5.
        func letterhead(_ text: String) -> DetectedSender? {
            detect([L(text, x: 25, top: 12, size: 12)] + Self.recipient)
        }
        #expect(letterhead("Please send the form to Fabrikam Inc. by mail.") == nil)
        #expect(letterhead("Ihre Bestellung bei Beispiel GmbH") == nil)
        #expect(letterhead("Muster Versand GmbH Commerzbank AG") == nil)
        #expect(letterhead("Gesellschaft für Informatik e.V.") == .name("Gesellschaft für Informatik e.V."))
        #expect(letterhead("Muster Verwaltungs GmbH & Co. KG") == .name("Muster Verwaltungs GmbH & Co. KG"))
        #expect(letterhead("eBay GmbH") == .name("eBay GmbH"))
    }

    @Test(arguments: [
        "Muster AG & Co. KGaA", "Muster SE & Co. KGaA", "Muster GmbH & Co. KGaA", "Muster Ltd. & Co. KG",
        "Muster GmbH + Co. KG", "dm-drogerie markt GmbH + Co. KG", "Muster UG (haftungsbeschränkt) & Co. KG",
        "Bäckerei am Markt GmbH", "Verein zur Förderung der Musik e.V.", "Bank of Muster PLC",
    ])
    func aCombinedLegalFormIsOneName(name: String) {
        // DN1 of #204.
        #expect(detect([L(name, x: 25, top: 12, size: 12)] + Self.recipient) == .name(name), "\(name)")
    }

    @Test func aLeftBlockWithoutAPostcodeKeepsTheRightWindow() {
        // DB2 of #204: a left reference block or place line is no recipient block.
        let block = [
            L("Herr", x: 125, top: 53, size: 11), L("Max Mustermann", x: 125, top: 58, size: 11),
            L("Seestrasse 5", x: 125, top: 63, size: 11), L("8002 Zürich", x: 125, top: 68, size: 11),
        ]
        let references = [
            L("Ihr Kontakt: Erika Beispiel", x: 20, top: 50, size: 9),
            L("Telefon 044 123 45 67", x: 20, top: 55, size: 9),
        ]
        let letterhead = L("Muster AG", x: 20, top: 15, size: 20)
        #expect(detect([letterhead] + references + block) == .name("Muster AG"))
        // A left block with a postcode is the recipient block: the right block is info-block letterhead again.
        let leftAddress = [
            L("Familie Mustermann", x: 20, top: 50, size: 11), L("8002 Zürich", x: 20, top: 55, size: 11),
        ]
        #expect(describe(detect([letterhead] + leftAddress + block)) == "known Max Mustermann")
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
        ("din-b-letterhead-no-return", "none"), ("swiss-right-window-125", "structural Muster AG"),
        ("swiss-right-window-130", "structural Muster AG"), ("swiss-left-references", "structural Muster AG"),
        ("swiss-left-date", "structural Muster AG"), ("us-letterhead-springfield", "known Contoso Supplies"),
        ("us-legal-letterhead-springfield", "known Contoso Supplies"),
        ("uk-letterhead-oxford", "known Brightwater Opticians"),
        ("din-a-small-recipient", "structural Muster Versicherung AG"),
        ("us-half-inch-margin", "known Northwind Dental Care"),
    ])
    func reviewCase(id: String, expected: String) throws {
        let letter = try #require(SyntheticLetters.letter(id))
        let found = SenderDetector.detect(in: letter.layout, known: Self.records(letter.knownNames))
        #expect(describe(found) == expected, "\(id)")
        for name in [
            letter.recipient, "Commerzbank AG", "Stadtsparkasse München", "Amtsgericht München", "Portland",
            "Manchester", "Springfield", "Oxford",
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
