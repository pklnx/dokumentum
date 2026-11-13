import Foundation

/// One synthetic letter of `SyntheticLetters`: values only, positions in millimetres from the page's top-left edge.
public struct SyntheticLetter: Sendable {
    /// A line of text: its left edge and top in millimetres, its font size in points. Its box is estimated from the
    /// font size (height: one em; width: half an em per character).
    public struct Line: Sendable, Equatable {
        public var text: String
        public var x: Double
        public var top: Double
        public var size: Double

        public init(_ text: String, x: Double, top: Double, size: Double) {
            self.text = text
            self.x = x
            self.top = top
            self.size = size
        }

        public var height: Double { size * DetectionLimits.millimetresPerPoint }
        public var width: Double { Double(text.count) * size * 0.5 * DetectionLimits.millimetresPerPoint }
    }

    /// What `SenderDetector` must find, with the letter's recipient and `otherKnown` as the known correspondents.
    public enum ExpectedSender: Equatable, Sendable {
        /// The known correspondent with this name.
        case known(String)
        /// This structural name.
        case structural(String)
        case none
    }

    public let id: String
    /// What the letter shows, and which review case it is.
    public let summary: String
    /// The page in millimetres.
    public let pageWidth: Double
    public let pageHeight: Double
    public let lines: [Line]
    /// The recipient's name: always among the known correspondents (B1.5).
    public let recipient: String
    /// Further known correspondents (a bank, the sender itself).
    public let otherKnown: [String]
    public let createdAt: Date
    public let sender: ExpectedSender
    public let date: SuggestedDate?

    /// The known correspondents' names: the recipient first.
    public var knownNames: [String] { [recipient] + otherKnown }

    /// The page as `SenderDetector` reads it.
    public var layout: PageLayout {
        SyntheticLetters.layout(lines, width: pageWidth, height: pageHeight)
    }

    /// The page's text as the text stage stores it: one line per layout line, top to bottom, left to right.
    public var text: String {
        lines.sorted { ($0.top, $0.x) < ($1.top, $1.x) }.map(\.text).joined(separator: "\n")
    }

    /// The same letter on a page `factor` times as large (a photo at another resolution).
    func scaled(by factor: Double, id: String, summary: String) -> SyntheticLetter {
        SyntheticLetter(
            id: id, summary: summary, pageWidth: pageWidth * factor, pageHeight: pageHeight * factor,
            lines: lines.map { Line($0.text, x: $0.x * factor, top: $0.top * factor, size: $0.size * factor) },
            recipient: recipient, otherKnown: otherKnown, createdAt: createdAt, sender: sender, date: date)
    }

    /// The same letter, at the same millimetres from the top-left edge, on another page size.
    func onPage(width: Double, height: Double, id: String, summary: String) -> SyntheticLetter {
        SyntheticLetter(
            id: id, summary: summary, pageWidth: width, pageHeight: height, lines: lines, recipient: recipient,
            otherKnown: otherKnown, createdAt: createdAt, sender: sender, date: date)
    }
}

/// Synthetic German and English letters for the detectors (plan of #11, Tests part 1; review S1–S9, S3a–c,
/// probe 2; re-review N-r2, N-r3, N-r4): values only, as `SyntheticCorpus` is. Every name, address, number and
/// account in them is invented. Part 2 renders them as text PDFs and image-only pages.
///
/// Every letter is evaluated with its recipient among the known correspondents (B1.5); all were "received" on
/// 2026-11-14.
public enum SyntheticLetters {
    /// 2026-11-14 10:00 UTC.
    public static let createdAt = Date(timeIntervalSince1970: 1_794_650_400)
    static let november13 = SuggestedDate(day: 13, month: 11, year: 2026)

    /// A layout from lines in millimetres on a page of `width` × `height` millimetres.
    public static func layout(_ lines: [SyntheticLetter.Line], width: Double = 210, height: Double = 297) -> PageLayout
    {
        let points = DetectionLimits.millimetresPerPoint
        return PageLayout(
            width: width / points, height: height / points,
            lines: lines.map { line in
                PageLayout.Line(
                    text: line.text,
                    box: .init(
                        x: line.x / width, y: line.top / height, width: line.width / width,
                        height: line.height / height))
            })
    }

    /// The letter with this id.
    public static func letter(_ id: String) -> SyntheticLetter? {
        all.first { $0.id == id }
    }

    private static func letter(
        _ id: String, _ summary: String, page: (width: Double, height: Double) = DetectionLimits.a4,
        recipient: String, known: [String] = [], sender: SyntheticLetter.ExpectedSender, date: SuggestedDate?,
        _ lines: [SyntheticLetter.Line]
    ) -> SyntheticLetter {
        SyntheticLetter(
            id: id, summary: summary, pageWidth: page.width, pageHeight: page.height, lines: lines,
            recipient: recipient, otherKnown: known, createdAt: createdAt, sender: sender, date: date)
    }

    /// Short, for the tables below.
    typealias L = SyntheticLetter.Line

    static let owner = "Max Mustermann"
    static let germanRecipient: [L] = [
        L("Max Mustermann", x: 25, top: 40, size: 11), L("Musterweg 2", x: 25, top: 45, size: 11),
        L("80331 München", x: 25, top: 50, size: 11),
    ]
    static let germanBody: [L] = [
        L("Sehr geehrter Herr Mustermann,", x: 25, top: 105, size: 11),
        L("vielen Dank für Ihr Schreiben. Anbei erhalten Sie die Unterlagen.", x: 25, top: 112, size: 11),
        L("Mit freundlichen Grüßen", x: 25, top: 130, size: 11),
    ]

    /// A DIN 5008 form B letter with a return-address line, for the page-size cases (N-r4).
    static let stadtbibliothek = letter(
        "din-b-stadtbibliothek", "DIN 5008 form B, return-address line at 46 mm, on A4",
        recipient: owner, sender: .structural("Stadtbibliothek Musterstadt"), date: november13,
        [
            L("Stadtbibliothek Musterstadt", x: 25, top: 15, size: 16),
            L("Stadtbibliothek Musterstadt · Postfach 5 55 · 80300 Musterstadt", x: 25, top: 46, size: 7),
            L("Herrn", x: 25, top: 52, size: 11), L("Max Mustermann", x: 25, top: 57, size: 11),
            L("Musterweg 2", x: 25, top: 62, size: 11), L("80331 München", x: 25, top: 67, size: 11),
            L("Datum: 13.11.2026", x: 125, top: 57, size: 9),
            L("Erinnerung an die Leihfrist", x: 25, top: 100, size: 11),
        ] + germanBody.map { L($0.text, x: $0.x, top: $0.top + 10, size: $0.size) })

    /// The probe-2 letter of the review: an info block at 125 mm beside the recipient, and a three-column footer
    /// (company | managing director, register court, VAT id | bank). Its letterhead is a logo text without a legal
    /// form, so that the footer decides.
    static let probe2Lines: [L] = [
        L("Muster Versand", x: 20.1, top: 17.8, size: 16),
        L("Max Mustermann", x: 20.1, top: 50.5, size: 11), L("Kundennummer: 4711", x: 124.9, top: 50.5, size: 9),
        L("Musterweg 2", x: 20.1, top: 56.4, size: 11), L("Datum: 13.11.2026", x: 124.9, top: 56.4, size: 9),
        L("80331 Musterstadt", x: 20.1, top: 62.3, size: 11),
        L("Sehr geehrter Herr Mustermann, vielen Dank für Ihre Bestellung.", x: 20.1, top: 118.8, size: 11),
        L("Muster Versand GmbH", x: 20.1, top: 273.2, size: 7),
        L("Geschäftsführer: Erika Beispiel", x: 81.1, top: 273.2, size: 7),
        L("Bankverbindung", x: 148.2, top: 273.2, size: 7),
        L("Musterstraße 1, 12345 Musterstadt", x: 20.1, top: 277.7, size: 7),
        L("Amtsgericht Musterstadt HRB 1234", x: 81.1, top: 277.7, size: 7),
        L("Commerzbank AG", x: 148.2, top: 277.7, size: 7),
        L("Telefon 0123 456789", x: 20.1, top: 282.2, size: 7),
        L("USt-IdNr. DE123456789", x: 81.1, top: 282.2, size: 7),
        L("IBAN DE12 3456 7890 1234 5678 90", x: 148.2, top: 282.2, size: 7),
    ]

    /// A shop's letterhead and footer around the one-line addresses of S3a–S3c.
    static func shop(_ address: [L]) -> [L] {
        [L("Muster Shop", x: 20, top: 12, size: 14)] + address + [
            L("Vielen Dank für Ihren Einkauf.", x: 20, top: 110, size: 11),
            L("Muster Shop GmbH · Hauptstraße 1 · 80331 München", x: 20, top: 280, size: 7),
        ]
    }

    public static let all: [SyntheticLetter] = [
        letter(
            "din-a-stadtwerke", "S9, the control: DIN 5008 form A with a return-address line",
            recipient: owner, sender: .structural("Stadtwerke Musterstadt GmbH"), date: november13,
            [
                L("Stadtwerke Musterstadt", x: 125, top: 12, size: 16),
                L("Stadtwerke Musterstadt GmbH · Postfach 12 34 · 80287 Musterstadt", x: 25, top: 29, size: 7),
                L("Herrn", x: 25, top: 35, size: 11),
                L("Kundennummer: 4711", x: 125, top: 40, size: 9), L("Datum: 13.11.2026", x: 125, top: 45, size: 9),
                L("Jahresabrechnung Strom 2026", x: 25, top: 95, size: 12),
            ] + germanRecipient + germanBody),
        stadtbibliothek,
        stadtbibliothek.onPage(
            width: DetectionLimits.usLetter.width, height: DetectionLimits.usLetter.height,
            id: "din-b-us-letter", summary: "the form B letter at the same millimetres on US Letter (N-r4)"),
        stadtbibliothek.onPage(
            width: DetectionLimits.usLegal.width, height: DetectionLimits.usLegal.height,
            id: "din-b-us-legal", summary: "the form B letter at the same millimetres on US Legal (N-r4)"),
        stadtbibliothek.scaled(
            by: 1000 * DetectionLimits.millimetresPerPoint / 210, id: "din-b-odd-size",
            summary: "the form B letter as a photo page of 1000 points width, not a standard size (N-r4)"),
        letter(
            "din-b-letterhead-40",
            "form B, a left letterhead down to 40 mm with a small address line in form A's zone, then the "
                + "return-address line",
            recipient: owner, known: ["Muster Versicherung AG"], sender: .known("Muster Versicherung AG"),
            date: november13,
            [
                L("Muster Versicherung AG", x: 25, top: 15, size: 14),
                L("Muster Versicherung AG · Versicherungsplatz 1 · 80001 München", x: 25, top: 26, size: 7),
                L("Telefon 089 123456 · Telefax 089 123457", x: 25, top: 31, size: 7),
                L("Hauptverwaltung München", x: 25, top: 36, size: 9),
                L("Muster Versicherung AG · Postfach 10 01 · 80001 München", x: 25, top: 46, size: 7),
                L("Herrn", x: 25, top: 52, size: 11), L("Max Mustermann", x: 25, top: 57, size: 11),
                L("Musterweg 2", x: 25, top: 62, size: 11), L("80331 München", x: 25, top: 67, size: 11),
                L("Versicherungsschein: 123-456", x: 125, top: 52, size: 9),
                L("Datum: 13.11.2026", x: 125, top: 57, size: 9),
            ] + germanBody),
        letter(
            "din-b-letterhead-no-return",
            "N-r3, the pinned miss: a left form B letterhead at 27–45 mm and no return-address line",
            recipient: owner, sender: .none, date: november13,
            [
                L("Beispiel Immobilien GmbH", x: 25, top: 28, size: 14),
                L("Lindenallee 5", x: 25, top: 35, size: 9), L("80335 München", x: 25, top: 40, size: 9),
                L("Max Mustermann", x: 25, top: 52, size: 11), L("Musterweg 2", x: 25, top: 57, size: 11),
                L("80331 München", x: 25, top: 62, size: 11), L("Datum: 13.11.2026", x: 125, top: 52, size: 9),
                L("Beispiel Immobilien GmbH · Lindenallee 5 · 80335 München", x: 25, top: 280, size: 7),
            ] + germanBody),
        letter(
            "finanzamt", "an authority: return-address line `Finanzamt Musterstadt · Postfach …`",
            recipient: owner, sender: .structural("Finanzamt Musterstadt"), date: november13,
            [
                L("Finanzamt Musterstadt", x: 125, top: 12, size: 12),
                L("Finanzamt Musterstadt · Postfach 10 20 30 · 80284 Musterstadt", x: 25, top: 29, size: 7),
                L("Herrn", x: 25, top: 35, size: 11),
                L("Steuernummer: 123/456/78901", x: 125, top: 40, size: 9),
                L("Datum 13.11.2026", x: 125, top: 45, size: 9),
                L("Bescheid für 2025 über Einkommensteuer", x: 25, top: 95, size: 12),
                L("Öffnungszeiten: Mo–Fr 8–12 Uhr", x: 25, top: 280, size: 7),
            ] + germanRecipient + germanBody),
        letter(
            "rechnung-zeitraum", "an invoice with `Rechnungsdatum`, a service period, a due date and a column footer",
            recipient: owner, sender: .structural("Muster Versand GmbH"), date: november13,
            [
                L("Muster Versand GmbH", x: 25, top: 12, size: 16),
                L("Rechnungsnummer: RE-2026-11-13-001", x: 125, top: 40, size: 9),
                L("Rechnungsdatum: 13.11.2026", x: 125, top: 45, size: 9),
                L("Kundennummer: 4711", x: 125, top: 50, size: 9),
                L("Rechnung", x: 25, top: 95, size: 14),
                L("Leistungszeitraum: 01.10.2026 – 31.10.2026", x: 25, top: 105, size: 11),
                L("Zahlbar bis 27.11.2026 ohne Abzug.", x: 25, top: 160, size: 11),
                L("Muster Versand GmbH", x: 25, top: 275, size: 7),
                L("Hafenstraße 9, 20457 Hamburg", x: 25, top: 279, size: 7),
                L("Geschäftsführer: Erika Beispiel", x: 85, top: 275, size: 7),
                L("Amtsgericht Hamburg HRB 12345", x: 85, top: 279, size: 7),
                L("Bankverbindung", x: 150, top: 275, size: 7), L("Beispielbank AG", x: 150, top: 279, size: 7),
                L("IBAN DE12 3456 7890 1234 5678 90", x: 150, top: 283, size: 7),
            ] + germanRecipient),
        letter(
            "muenchen-den", "`München, den 13. November 2026` and `Ihr Schreiben vom 02.11.2026`",
            recipient: owner, sender: .structural("Hausverwaltung Beispiel"), date: november13,
            [
                L("Hausverwaltung Beispiel · Lindenstraße 4 · 80333 München", x: 25, top: 29, size: 7),
                L("Herrn", x: 25, top: 35, size: 11),
                L("Ihr Schreiben vom 02.11.2026", x: 125, top: 40, size: 9),
                L("München, den 13. November 2026", x: 125, top: 75, size: 11),
                L("Nebenkostenabrechnung 2025", x: 25, top: 95, size: 12),
            ] + germanRecipient + germanBody),
        letter(
            "versicherung-geburtsdatum",
            "an insurance letter: `Versicherungsnehmer`, a birth date, a contract start; the date only in the text",
            recipient: owner, sender: .structural("Beispiel Lebensversicherung AG"), date: november13,
            [
                L("Beispiel Lebensversicherung AG", x: 25, top: 12, size: 16),
                L("Versicherungsnehmer: Max Mustermann", x: 125, top: 40, size: 9),
                L("Geburtsdatum: 01.02.1980", x: 125, top: 45, size: 9),
                L("Vertragsbeginn: 01.12.2026", x: 125, top: 50, size: 9),
                L("Ihr Versicherungsschein vom 13. November 2026", x: 25, top: 95, size: 12),
            ] + germanRecipient + germanBody),
        letter(
            "zahlungserinnerung", "a reminder with a due date; the date only in the text",
            recipient: owner, sender: .structural("Muster Telekom GmbH"), date: november13,
            [
                L("Muster Telekom GmbH", x: 25, top: 12, size: 16),
                L("Zahlungserinnerung vom 13.11.2026", x: 25, top: 95, size: 12),
                L("Der Betrag von 49,99 EUR ist fällig am 27.11.2026.", x: 25, top: 105, size: 11),
            ] + germanRecipient),
        letter(
            "probe2-bank-known", "the review's probe 2, the owner's bank (`Commerzbank AG`) known",
            recipient: owner, known: ["Commerzbank AG"], sender: .structural("Muster Versand GmbH"), date: november13,
            probe2Lines),
        letter(
            "probe2-bank-unknown", "the review's probe 2, the bank unknown",
            recipient: owner, sender: .structural("Muster Versand GmbH"), date: november13, probe2Lines),
        letter(
            "S1-us-portland", "S1: a US letter, no return-address line, the recipient's `Portland, OR 97201`",
            page: DetectionLimits.usLetter, recipient: "John Smith", known: ["Northwind Dental Care"],
            sender: .known("Northwind Dental Care"), date: november13,
            [
                L("Northwind Dental Care", x: 82, top: 12, size: 16),
                L("November 13, 2026", x: 25.9, top: 40, size: 11),
                L("John Smith", x: 25.9, top: 54, size: 11), L("45 Oak Avenue", x: 25.9, top: 59.5, size: 11),
                L("Portland, OR 97201", x: 25.9, top: 65, size: 11),
                L("Dear Mr. Smith,", x: 25.9, top: 82, size: 11),
                L("your next check-up is due in December.", x: 25.9, top: 89, size: 11),
            ]),
        letter(
            "S1b-us-city-in-zone", "S1 with the recipient block higher: `Portland, OR 97201` in form B's zone",
            page: DetectionLimits.usLetter, recipient: "John Smith", known: ["Northwind Dental Care"],
            sender: .known("Northwind Dental Care"), date: november13,
            [
                L("Northwind Dental Care", x: 82, top: 12, size: 16),
                L("November 13, 2026", x: 25.9, top: 25, size: 11),
                L("John Smith", x: 25.9, top: 38, size: 11), L("45 Oak Avenue", x: 25.9, top: 43.5, size: 11),
                L("Portland, OR 97201", x: 25.9, top: 49, size: 11),
                L("Dear Mr. Smith,", x: 25.9, top: 70, size: 11),
                L("your next check-up is due in December.", x: 25.9, top: 77, size: 11),
            ]),
        letter(
            "S2b-uk-town-in-zone", "S2 with the recipient block higher: `Manchester, M1 1AE` in form B's zone",
            recipient: "Jane Doe", sender: .structural("Brightwater Opticians Ltd"), date: november13,
            [
                L("Brightwater Opticians Ltd", x: 126, top: 15, size: 14),
                L("13 November 2026", x: 126, top: 40, size: 11),
                L("Ms Jane Doe", x: 21, top: 38, size: 11), L("12 Mill Lane", x: 21, top: 43.5, size: 11),
                L("Manchester, M1 1AE", x: 21, top: 49, size: 11),
                L("Dear Ms Doe,", x: 21, top: 70, size: 11),
                L("your new glasses are ready for collection.", x: 21, top: 77, size: 11),
            ]),
        letter(
            "S2-uk-manchester", "S2: a UK letter, the recipient's `Manchester, M1 1AE`",
            recipient: "Jane Doe", sender: .structural("Brightwater Opticians Ltd"), date: november13,
            [
                L("Brightwater Opticians Ltd", x: 126, top: 15, size: 14),
                L("13 November 2026", x: 126, top: 40, size: 11),
                L("Ms Jane Doe", x: 21, top: 53.5, size: 11), L("12 Mill Lane", x: 21, top: 59.4, size: 11),
                L("Manchester, M1 1AE", x: 21, top: 65.3, size: 11),
                L("Dear Ms Doe,", x: 21, top: 95, size: 11),
                L("your new glasses are ready for collection.", x: 21, top: 102, size: 11),
            ]),
        letter(
            "S3-shop-delivery", "S3: a shop invoice, a one-line delivery address labelled `Lieferung an:`",
            recipient: owner, sender: .structural("Muster Shop GmbH"), date: november13,
            [
                L("Rechnung", x: 21, top: 15, size: 14), L("Muster Shop GmbH", x: 126, top: 15, size: 12),
                L("Lieferung an: Max Mustermann, Musterstraße 1, 80331 München", x: 21, top: 59, size: 11),
                L("Rechnungsdatum: 13.11.2026", x: 21, top: 70, size: 11),
                L("Vielen Dank für Ihre Bestellung.", x: 21, top: 100, size: 11),
            ]),
        letter(
            "S3a-receipt", "S3a: a one-line address alone in the field (a shop receipt)",
            recipient: owner, sender: .structural("Muster Shop GmbH"), date: november13,
            shop([
                L("Max Mustermann, Musterstraße 1, 80331 München", x: 20, top: 50, size: 11),
                L("Kassenbon vom 13.11.2026", x: 20, top: 100, size: 11),
            ])),
        letter(
            "S3b-body-below", "S3b: a one-line address, then two body lines of the same size",
            recipient: owner, sender: .structural("Muster Shop GmbH"), date: november13,
            shop([
                L("Max Mustermann, Musterstraße 1, 80331 München", x: 20, top: 50, size: 11),
                L("Kundennummer 4711", x: 20, top: 60, size: 11), L("Rechnung Nr. 2026-118", x: 20, top: 66, size: 11),
                L("Rechnungsdatum: 13.11.2026", x: 125, top: 60, size: 9),
            ])),
        letter(
            "S3c-labelled", "S3c: the one-line address labelled `Rechnungsanschrift:`",
            recipient: owner, sender: .structural("Muster Shop GmbH"), date: november13,
            shop([
                L("Rechnungsanschrift: Max Mustermann, Musterstraße 1, 80331 München", x: 20, top: 50, size: 11),
                L("Kundennummer 4711", x: 20, top: 60, size: 11), L("Datum: 13.11.2026", x: 125, top: 40, size: 9),
            ])),
        letter(
            "S3c-info-block", "S3c's labelled address in the info-block column, the owner nowhere else",
            recipient: owner, sender: .structural("Muster Shop GmbH"), date: november13,
            shop([
                L("Rechnungsanschrift: Max Mustermann, Musterstraße 1, 80331 München", x: 125, top: 40, size: 8),
                L("Datum: 13.11.2026", x: 125, top: 45, size: 8),
            ])),
        letter(
            "S4-insurer-info-block", "S4: form A, the info block says `Versicherungsnehmer: <owner>`",
            recipient: owner, sender: .structural("Muster Versicherung AG"), date: november13,
            [
                L("Muster Versicherung AG", x: 21, top: 12, size: 16),
                L("Max Mustermann", x: 21, top: 44.6, size: 11), L("Musterstraße 1", x: 21, top: 50.5, size: 11),
                L("80331 München", x: 21, top: 56.4, size: 11),
                L("Versicherungsnehmer: Max Mustermann", x: 126, top: 44.6, size: 9),
                L("Vertragsnummer: 123-456", x: 126, top: 50.5, size: 9),
                L("Datum: 13.11.2026", x: 126, top: 56.4, size: 9),
            ] + germanBody),
        letter(
            "S5-us-invoice-ship-to", "S5: a US invoice, `Bill To` on the left and `Ship To` in the info-block column",
            page: DetectionLimits.usLetter, recipient: "John Smith", sender: .structural("Fabrikam, Inc."),
            date: november13,
            [
                L("INVOICE", x: 21.6, top: 14, size: 16), L("Fabrikam, Inc.", x: 130, top: 14, size: 12),
                L("Invoice Date: November 13, 2026", x: 130, top: 30, size: 9),
                L("Bill To", x: 21.6, top: 50.3, size: 10), L("John Smith", x: 21.6, top: 55.9, size: 10),
                L("45 Oak Avenue", x: 21.6, top: 60.5, size: 10),
                L("Portland, OR 97201", x: 21.6, top: 65, size: 10),
                L("Ship To", x: 130, top: 50.3, size: 10), L("John Smith", x: 130, top: 55.9, size: 10),
                L("45 Oak Avenue", x: 130, top: 60.5, size: 10), L("Portland, OR 97201", x: 130, top: 65, size: 10),
                L("Thank you for your business.", x: 21.6, top: 120, size: 10),
            ]),
        letter(
            "ship-to-only", "N-r2: only a right-hand `Ship To` block, the label on its own line",
            page: DetectionLimits.usLetter, recipient: "John Smith", sender: .structural("Contoso Supplies LLC"),
            date: november13,
            [
                L("Contoso Supplies LLC", x: 21.6, top: 14, size: 14),
                L("Packing Slip", x: 21.6, top: 40, size: 14),
                L("Ship To", x: 130, top: 40, size: 10), L("John Smith", x: 130, top: 45, size: 10),
                L("45 Oak Avenue", x: 130, top: 49.5, size: 10), L("Portland, OR 97201", x: 130, top: 54, size: 10),
                L("Order Date: November 1, 2026", x: 21.6, top: 100, size: 10),
                L("Date: November 13, 2026", x: 21.6, top: 105, size: 10),
            ]),
        letter(
            "law-firm", "N4: a law firm whose name has a comma, return-address line split at `·`",
            recipient: owner, sender: .structural("Müller, Schmidt & Partner Rechtsanwälte PartG mbB"),
            date: november13,
            [
                L("Müller, Schmidt & Partner", x: 125, top: 12, size: 14),
                L(
                    "Müller, Schmidt & Partner Rechtsanwälte PartG mbB · Kanzleistraße 1 · 80333 München", x: 25,
                    top: 29, size: 7),
                L("Herrn", x: 25, top: 35, size: 11), L("Datum: 13.11.2026", x: 125, top: 45, size: 9),
            ] + germanRecipient + germanBody),
        letter(
            "uk-acme", "a UK letter: `Acme Widgets Ltd`, `13 November 2026`",
            recipient: "John Smith", sender: .structural("Acme Widgets Ltd"), date: november13,
            [
                L("Acme Widgets Ltd", x: 126, top: 15, size: 16),
                L("Unit 4, Riverside Park", x: 126, top: 22, size: 9), L("Leeds LS1 4AB", x: 126, top: 26, size: 9),
                L("Mr John Smith", x: 21, top: 50, size: 11), L("1 High Street", x: 21, top: 55, size: 11),
                L("Oxford OX1 1AA", x: 21, top: 60, size: 11), L("13 November 2026", x: 21, top: 75, size: 11),
                L("Dear Mr Smith,", x: 21, top: 92, size: 11),
                L("please find our new catalogue enclosed.", x: 21, top: 99, size: 11),
            ]),
        letter(
            "us-invoice", "a US invoice: `Invoice Date`, `Order Date`, `Due Date`",
            page: DetectionLimits.usLetter, recipient: "Jane Doe", sender: .structural("Tailspin Toys Inc."),
            date: november13,
            [
                L("Tailspin Toys Inc.", x: 21.6, top: 14, size: 16),
                L("Bill To", x: 21.6, top: 50, size: 10), L("Jane Doe", x: 21.6, top: 55, size: 10),
                L("200 Pine Street", x: 21.6, top: 59.5, size: 10), L("Seattle, WA 98101", x: 21.6, top: 64, size: 10),
                L("Invoice Date: November 13, 2026", x: 130, top: 50, size: 10),
                L("Order Date: November 1, 2026", x: 130, top: 55, size: 10),
                L("Due Date: December 13, 2026", x: 130, top: 60, size: 10),
                L("Total due: $120.00", x: 21.6, top: 120, size: 10),
            ]),
        letter(
            "us-letter-slash", "a US letter with `11/13/2026` and an ambiguous `05/06/2026`",
            page: DetectionLimits.usLetter, recipient: "Jane Doe", sender: .structural("Northwind Traders LLC"),
            date: november13,
            [
                L("Northwind Traders LLC", x: 21.6, top: 14, size: 16), L("11/13/2026", x: 21.6, top: 35, size: 11),
                L("Ms Jane Doe", x: 21.6, top: 50, size: 11), L("200 Pine Street", x: 21.6, top: 55, size: 11),
                L("Seattle, WA 98101", x: 21.6, top: 60, size: 11),
                L("Thank you for your order of 05/06/2026.", x: 21.6, top: 85, size: 11),
            ]),
        letter(
            "future-year", "a date with a future year (an OCR misread of 2026): no date",
            recipient: owner, sender: .structural("Gemeinde Musterdorf"), date: nil,
            [
                L("Gemeinde Musterdorf · Rathausplatz 1 · 85000 Musterdorf", x: 25, top: 29, size: 7),
                L("Herrn", x: 25, top: 35, size: 11), L("Datum: 13.11.2028", x: 125, top: 45, size: 9),
            ] + germanRecipient + germanBody),
        letter(
            "nothing", "a page with neither a sender nor a date", recipient: owner, sender: .none, date: nil,
            germanBody),
        letter(
            "S6-footer-bank-known", "S6: the owner's bank on its own line in a footer column, known",
            recipient: owner, known: ["Stadtsparkasse München", "Praxis Dr. med. Hans Beispiel"],
            sender: .known("Praxis Dr. med. Hans Beispiel"), date: november13,
            [
                L("Max Mustermann", x: 21, top: 50.5, size: 11), L("Datum: 13.11.2026", x: 136.5, top: 50.5, size: 9),
                L("Praxis Dr. med. Hans Beispiel", x: 21, top: 273.2, size: 7),
                L("Bankverbindung", x: 136.5, top: 273.2, size: 7),
                L("Stadtsparkasse München", x: 136.5, top: 277.7, size: 7),
                L("IBAN DE12 7015 0000 0000 1234 56", x: 136.5, top: 282.2, size: 7),
            ]),
        letter(
            "S7-footer-bank-unknown", "S7: an unknown `Commerzbank AG` on its own line in a footer column",
            recipient: owner, sender: .none, date: november13,
            [
                L("Max Mustermann", x: 21, top: 50.5, size: 11), L("Datum: 13.11.2026", x: 136.5, top: 50.5, size: 9),
                L("Praxis Dr. med. Hans Beispiel", x: 21, top: 273.2, size: 7),
                L("Bankverbindung", x: 136.5, top: 273.2, size: 7),
                L("Commerzbank AG", x: 136.5, top: 277.7, size: 7),
                L("IBAN DE12 7015 0000 0000 1234 56", x: 136.5, top: 282.2, size: 7),
            ]),
        letter(
            "S8-footer-court-known", "S8: a register line naming a known court",
            recipient: owner, known: ["Amtsgericht München", "Kanzlei Beispiel Rechtsanwälte"],
            sender: .known("Kanzlei Beispiel Rechtsanwälte"), date: november13,
            [
                L("Max Mustermann", x: 21, top: 50.5, size: 11), L("Datum: 13.11.2026", x: 126, top: 50.5, size: 9),
                L("Kanzlei Beispiel Rechtsanwälte", x: 21, top: 273.2, size: 7),
                L("Amtsgericht München PR 1234", x: 84, top: 273.2, size: 7),
            ]),
        // Fix round 1 of #204 (review B1, B2, N3, N11).
        swissWindow(at: 125, letterhead: "Muster", returnLine: true, id: "swiss-right-window-125"),
        swissWindow(at: 130, letterhead: "Muster AG", returnLine: false, id: "swiss-right-window-130"),
        letter(
            "us-letterhead-springfield",
            "B2: a US letterhead's small `Springfield, IL 62701` line in form A's zone: a town, not a name",
            page: DetectionLimits.usLetter, recipient: "John Smith", known: ["Contoso Supplies"],
            sender: .known("Contoso Supplies"), date: november13, springfieldLines),
        letter(
            "us-legal-letterhead-springfield", "B2: the same letterhead on US Legal",
            page: DetectionLimits.usLegal, recipient: "John Smith", known: ["Contoso Supplies"],
            sender: .known("Contoso Supplies"), date: november13, springfieldLines),
        letter(
            "uk-letterhead-oxford", "B2: a UK letterhead's small `Oxford, OX1 1AA` line in form A's zone",
            recipient: "Jane Doe", known: ["Brightwater Opticians"], sender: .known("Brightwater Opticians"),
            date: november13,
            [
                L("Brightwater Opticians", x: 20, top: 12, size: 18),
                L("1 High Street", x: 20, top: 21.5, size: 8), L("Oxford, OX1 1AA", x: 20, top: 26, size: 8),
                L("Ms Jane Doe", x: 20, top: 45, size: 11), L("12 Mill Lane", x: 20, top: 50, size: 11),
                L("Manchester, M1 1AE", x: 20, top: 55, size: 11), L("13 November 2026", x: 20, top: 66, size: 11),
            ]),
        letter(
            "din-a-small-recipient",
            "N3: form A, the recipient in 9 pt with its street line in form B's zone, the body in 12 pt",
            recipient: owner, sender: .structural("Muster Versicherung AG"), date: november13,
            [
                L("Muster Versicherung AG · Postfach 1 · 80001 München", x: 25, top: 28, size: 7),
                L("Herrn Max Mustermann", x: 25, top: 36, size: 9),
                L("Musterweg 2, 80331 München", x: 25, top: 43, size: 9),
                L("Datum: 13.11.2026", x: 125, top: 36, size: 9),
                L("Ihre Police", x: 25, top: 60, size: 12),
                L("Sehr geehrter Herr Mustermann,", x: 25, top: 70, size: 12),
                L("anbei Ihre Unterlagen.", x: 25, top: 76, size: 12),
            ]),
        letter(
            "uk-small-recipient", "N3: a UK form A letter, the recipient in 9 pt, `Manchester, M1 1AE` at 43 mm",
            recipient: "Jane Doe", sender: .structural("Brightwater Opticians Ltd"), date: november13,
            [
                L("Brightwater Opticians Ltd · 1 High Street · Oxford OX1 1AA", x: 20, top: 28, size: 7),
                L("Ms Jane Doe", x: 20, top: 34, size: 9), L("13 November 2026", x: 130, top: 34, size: 9),
                L("12 Mill Lane", x: 20, top: 38.5, size: 9), L("Manchester, M1 1AE", x: 20, top: 43, size: 9),
                L("Your appointment", x: 20, top: 60, size: 12), L("Dear Ms Doe,", x: 20, top: 70, size: 12),
                L("your new glasses are ready.", x: 20, top: 76, size: 12),
            ]),
        letter(
            "us-half-inch-margin",
            "N11: a US letter with half-inch margins (the recipient at 12.7 mm) and the owner in the info block",
            page: DetectionLimits.usLetter, recipient: "John Smith", known: ["Northwind Dental Care"],
            sender: .known("Northwind Dental Care"), date: november13,
            [
                L("Northwind Dental Care", x: 140, top: 12, size: 16),
                L("Account: John Smith", x: 140, top: 25, size: 9),
                L("November 13, 2026", x: 12.7, top: 40, size: 11), L("John Smith", x: 12.7, top: 50, size: 11),
                L("123 Main Street", x: 12.7, top: 55, size: 11), L("Portland, OR 97201", x: 12.7, top: 60, size: 11),
                L("Dear Mr. Smith,", x: 12.7, top: 75, size: 11),
            ]),
    ]

    /// A US letterhead with a small town line in form A's zone (review A5 of #204).
    static let springfieldLines: [L] = [
        L("Contoso Supplies", x: 25.4, top: 12, size: 18), L("100 Industrial Way", x: 25.4, top: 20.5, size: 8),
        L("Springfield, IL 62701", x: 25.4, top: 25, size: 8), L("November 13, 2026", x: 25.4, top: 40, size: 11),
        L("John Smith", x: 25.4, top: 50, size: 11), L("123 Main Street", x: 25.4, top: 55, size: 11),
        L("Portland, OR 97201", x: 25.4, top: 60, size: 11), L("Dear Mr. Smith,", x: 25.4, top: 72, size: 11),
    ]

    /// A Swiss right-window letter (review B1 of #204): the recipient block at `x`, nothing in the left field.
    static func swissWindow(at x: Double, letterhead: String, returnLine: Bool, id: String) -> SyntheticLetter {
        let window: [L] =
            (returnLine ? [L("Muster AG, Bahnhofstrasse 1, 8001 Zürich", x: x, top: 48, size: 7)] : []) + [
                L("Herr", x: x, top: 53, size: 11), L("Max Mustermann", x: x, top: 58, size: 11),
                L("Seestrasse 5", x: x, top: 63, size: 11), L("8002 Zürich", x: x, top: 68, size: 11),
            ]
        return letter(
            id,
            "B1: a Swiss right-window letter at \(Int(x)) mm, letterhead `\(letterhead)`"
                + (returnLine ? ", with a return-address line" : ""),
            recipient: owner, sender: .structural("Muster AG"), date: november13,
            [
                L(letterhead, x: 20, top: 15, size: 20), L("Zürich, 13. November 2026", x: 20, top: 90, size: 11),
            ] + window + germanBody)
    }
}
