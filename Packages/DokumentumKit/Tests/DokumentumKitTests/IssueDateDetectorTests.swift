import DokumentumKit
import Foundation
import Testing

/// The issue date from a letter's text (#11, part 1; plan Approach 2).
struct IssueDateDetectorTests {
    /// 2026-11-14 10:00 UTC.
    static let createdAt = SyntheticLetters.createdAt
    static let november13 = SuggestedDate(day: 13, month: 11, year: 2026)

    private func detect(_ text: String, createdAt: Date = createdAt) -> SuggestedDate? {
        IssueDateDetector.detect(in: text, createdAt: createdAt)
    }

    private func date(_ day: Int, _ month: Int, _ year: Int) -> SuggestedDate {
        SuggestedDate(day: day, month: month, year: year)
    }

    // MARK: Forms

    @Test(arguments: [
        "13.11.2026", "13.11.26", "13. 11. 2026", "13. November 2026", "13 November 2026", "13. Nov. 2026",
        "13.Nov.2026", "13. Nov 2026", "13 november 2026",
    ])
    func germanForms(text: String) {
        #expect(detect(text) == Self.november13, "\(text)")
    }

    @Test(arguments: [
        "13 November 2026", "13th November 2026", "November 13, 2026", "November 13th, 2026", "Nov 13, 2026",
        "Nov. 13, 2026", "13-Nov-2026", "13th of November 2026", "2026-11-13",
    ])
    func englishAndISOForms(text: String) {
        #expect(detect(text) == Self.november13, "\(text)")
    }

    @Test func singleDigitsAndOtherSpellings() {
        #expect(detect("3.1.2026") == date(3, 1, 2026))
        #expect(detect("3. Jänner 2026") == date(3, 1, 2026), "Austrian January")
        #expect(detect("1. März 2026") == date(1, 3, 2026))
        #expect(detect("5. Sept. 2026") == date(5, 9, 2026))
        #expect(detect("Sept 5, 2026") == date(5, 9, 2026))
        #expect(detect("1st May 2026") == date(1, 5, 2026))
        #expect(detect("2nd June 2026") == date(2, 6, 2026))
        #expect(detect("3rd July 2026") == date(3, 7, 2026))
    }

    @Test func slashesOnlyWhenTheOrderIsClear() {
        #expect(detect("13/11/2026") == Self.november13, "day first: the day is above 12")
        #expect(detect("11/13/2026") == Self.november13, "month first: the day is above 12")
        #expect(detect("05/06/2026") == nil, "ambiguous")
        #expect(detect("05/05/2026") == date(5, 5, 2026), "the same date either way")
        #expect(detect("Your order of 05/06/2026\nDate: 11/13/2026") == Self.november13)
    }

    @Test func notInsideANumberOrCode() {
        #expect(detect("Rechnungsnummer: RE-2026-11-13-001") == nil)
        #expect(detect("IBAN DE12 3456 7890 1234 5678 90") == nil)
        #expect(detect("Ziffer 113.11.2026") == nil)
        #expect(detect("Version 1.13.11.2026") == nil)
        #expect(detect("Az. 13.11.2026.5") == nil)
        #expect(detect("13.11.20261") == nil)
        #expect(detect("Rechnung RE-2026-11-13-001 vom 13.11.2026") == Self.november13)
    }

    @Test func invalidDatesAreNoDates() {
        #expect(detect("30.02.2026") == nil)
        #expect(detect("29.02.2025") == nil)
        #expect(detect("29.02.2024") == date(29, 2, 2024), "a leap year")
        #expect(detect("13.13.2026") == nil)
        #expect(detect("00.11.2026") == nil)
    }

    // MARK: The window and two-digit years

    @Test func theWindowRunsFrom1900ToCreatedAtPlus31Days() {
        #expect(detect("31.12.1899") == nil)
        #expect(detect("01.01.1900") == date(1, 1, 1900))
        // createdAt is 2026-11-14 10:00 UTC: + 31 days is 2026-12-15, + 32 days 2026-12-16.
        #expect(detect("15.12.2026") == date(15, 12, 2026), "createdAt + 31 days")
        #expect(detect("16.12.2026") == nil, "createdAt + 32 days")
        #expect(detect("13.11.2028") == nil, "an OCR misread of the year")
    }

    @Test func twoDigitYearsPivotAfterNextYear() {
        #expect(detect("13.11.26") == date(13, 11, 2026))
        #expect(detect("01.01.27") == nil, "2027 is createdAt's year + 1, so 20yy, and after the window")
        #expect(detect("13.11.28") == date(13, 11, 1928), "2028 is after createdAt's year + 1")
        #expect(detect("13.11.99") == date(13, 11, 1999))
        let december20 = Date(timeIntervalSince1970: 1_797_724_800)  // 2026-12-20 00:00 UTC
        #expect(detect("15.01.27", createdAt: december20) == date(15, 1, 2027), "in the window of a December letter")
        #expect(detect("15.01.28", createdAt: december20) == date(15, 1, 1928))
    }

    // MARK: Ignored dates

    @Test(arguments: [
        "Fällig am 27.11.2026", "Fälligkeit: 27.11.2026", "Fälligkeitsdatum: 27.11.2026", "zahlbar bis 27.11.2026",
        "Zahlungsziel 27.11.2026", "spätestens am 27.11.2026", "Payment due 27 November 2026",
        "Payable by November 27, 2026", "Please pay by 27/11/2026",
        "Geburtsdatum: 01.02.1980", "geb. 01.02.1980", "geboren am 1. Februar 1980", "Date of birth: 1 February 1980",
        "DOB: 01/02/1980", "born 1 February 1980",
        "Zeitraum 01.10.2026", "Leistungszeitraum: 01.10.2026", "Abrechnungszeitraum 01.10.2026",
        "Billing period: 1 October 2026",
        "gültig bis 31.12.2026", "Laufzeit: 01.01.2026", "Beginn: 01.12.2026", "Ende: 31.10.2026",
        "Vertragsbeginn 01.12.2026", "Kündigung zum 31.10.2026", "Frist: 27.11.2026", "valid until 31 October 2026",
        "Card expires 31.10.2026", "Deadline: October 31, 2026",
        "Order Date: November 1, 2026", "Start Date: 01.11.2026", "End Date: 01.11.2026", "Ship Date: 01.11.2026",
        "Shipping Date: 01.11.2026", "Effective Date: 01.11.2026", "Delivery Date: 01.11.2026",
        "Service Date: 01.11.2026", "Due Date: 01.12.2026", "Datum der Leistung: 01.11.2026",
        "Lieferdatum: 01.11.2026", "Leistungsdatum 01.11.2026", "Bestelldatum: 01.11.2026",
        "Ihr Schreiben vom 02.11.2026", "Ihre Nachricht vom 02.11.2026", "Ihr Zeichen ab-12 vom 02.11.2026",
        "Eingang 02.11.2026", "Termin am 20.11.2026", "Your letter of 2 November 2026", "Your ref. of 2 November 2026",
        "Received 2 November 2026", "Appointment: 20 November 2026",
        "Stand: 01.10.2026",
        // Fix round 1 of #204 (N8, N9).
        "Payment Date: 20.11.2026", "Birth Date: 1 February 1980", "Expiry Date: 31.12.2026",
        "Expiration Date: 31.12.2026", "Liefer-Datum: 10.11.2026", "Geb.-Datum: 05.03.1980",
        "Versicherungsbeginn: 01.12.2026", "Kündigungsfrist: 30.11.2026", "Vertragsende 31.12.2026",
        "Versicherungsende 31.12.2026", "Laufzeitende 31.12.2026", "Eingegangen 20. Nov. 2026",
        "zu Ihrem Schreiben vom 02.11.2026", "Ihre Anfrage vom 02.11.2026", "Ihrer Anfrage vom 02.11.2026",
        "Ihrer Nachricht vom 02.11.2026", "Posteingang 02.11.2026", "Liefertermin 20.11.2026",
    ])
    func aCuedDateIsIgnored(cued: String) {
        // Alone, the cued date would be the only date (tier 3); with a second date, it would make that ambiguous.
        #expect(detect(cued) == nil, "\(cued)")
        #expect(detect("Schreiben vom 13. November 2026\n\(cued)") == Self.november13, "\(cued)")
    }

    @Test func aCueCountsOnlyBeforeItsDateAndAfterThePreviousOne() {
        #expect(detect("Rechnung vom 13.11.2026, fällig am 27.11.2026") == Self.november13)
        #expect(detect("Fällig am 27.11.2026, Rechnung vom 13.11.2026") == Self.november13)
    }

    @Test func bothDatesOfARangeAreIgnored() {
        #expect(detect("01.10.2026 bis 31.10.2026") == nil)
        #expect(detect("01.10.2026 – 31.10.2026") == nil)
        #expect(detect("01.10.2026 - 31.10.2026") == nil)
        #expect(detect("vom 01.10.2026 bis zum 31.10.2026") == nil)
        #expect(detect("01.10.–31.10.2026") == nil)
        #expect(detect("1 October 2026 to 31 October 2026") == nil)
        #expect(detect("October 1, 2026 through October 31, 2026") == nil)
        #expect(detect("Schreiben vom 13.11.2026\nfür 01.10.2026 – 31.10.2026") == Self.november13)
    }

    // MARK: Tiers

    @Test func labelledBeatsStandaloneBeatsOnly() {
        let three = """
            Unsere Nachricht vom 01.11.2026
            10.11.2026
            Rechnungsdatum: 13.11.2026
            """
        #expect(detect(three) == Self.november13, "labelled")
        let two = """
            13.11.2026
            Unsere Nachricht vom 01.11.2026
            """
        #expect(detect(two) == Self.november13, "standalone")
        #expect(detect("Unsere Nachricht vom 13.11.2026") == Self.november13, "the only date")
        #expect(detect("Unsere Nachricht vom 13.11.2026 und vom 01.11.2026") == nil, "two only dates")
    }

    @Test(arguments: [
        "Rechnungsdatum 13.11.2026", "Belegdatum: 13.11.2026", "Ausstellungsdatum 13.11.2026",
        "ausgestellt am 13.11.2026", "erstellt am 13.11.2026", "Bescheiddatum: 13.11.2026",
        "Invoice date: November 13, 2026", "Issue date 13/11/2026", "Date of issue: 13 November 2026",
        "Issued on 13 November 2026", "Issued: 13 November 2026", "Statement date: 13.11.2026",
        "Dated 13 November 2026", "Datum: 13.11.2026", "Date: November 13, 2026", "Musterweg 2 Datum: 13.11.2026",
        "Rechnungs-Datum 13.11.2026", "München, den 13. November 2026", "London, 13 November 2026",
        "Frankfurt am Main, 13.11.2026",
    ])
    func aLabelledDateWinsOverAnotherDate(labelled: String) {
        // A standalone date in the first half would win tier 2; the label puts this one in tier 1.
        #expect(detect("01.11.2026\n\(labelled)") == Self.november13, "\(labelled)")
    }

    @Test func dateCountsAsALabelOnlyWithoutALetterWordBeforeIt() {
        // N1: a compound label that is not in the cue lists.
        #expect(detect("01.11.2026\nBilling Date: 13.11.2026") == date(1, 11, 2026))
        #expect(detect("Billing Date: 01.11.2026\nDate: 13.11.2026") == Self.november13)
        #expect(detect("01.11.2026\nMax Mustermann Datum: 13.11.2026") == date(1, 11, 2026))
    }

    @Test func aLabelAtTheEndOfThePreviousLineCounts() {
        // N3: an info block that PDFKit joined with the recipient block.
        // In each case 01.11.2026 is standalone in the first half (tier 2); only a label puts 13.11.2026 above it.
        let joined = """
            01.11.2026
            Max Mustermann Datum
            Musterweg 2 13.11.2026
            """
        #expect(detect(joined) == Self.november13)
        let colon = "01.11.2026\nMax Mustermann Rechnungsdatum:\nMusterweg 2 13.11.2026"
        #expect(detect(colon) == Self.november13)
        let notAtTheEnd = "01.11.2026\nMax Mustermann Datum\nMusterweg 2 13.11.2026 ab"
        #expect(detect(notAtTheEnd) == date(1, 11, 2026), "the date does not end its line")
        let compound = "13.11.2026\nOrder Date\n01.11.2026"
        #expect(detect(compound) == Self.november13, "a cue at the end of the previous line is no label")
    }

    @Test func aPlaceLineNeedsTheDateAtItsEnd() {
        #expect(detect("01.11.2026\nMünchen, den 13.11.2026 eingegangen") == date(1, 11, 2026))
        #expect(detect("01.11.2026\nIn der schönen Stadt München, 13.11.2026") == date(1, 11, 2026))
    }

    @Test func standaloneOnlyInTheFirstHalf() {
        let late = ["Absender", "Betreff", "Text", "Text", "Text", "13.11.2026"].joined(separator: "\n")
        #expect(detect(late) == Self.november13, "found as the only date")
        let lateWithAnother = late + "\nUnsere Nachricht vom 01.11.2026"
        #expect(detect(lateWithAnother) == nil, "not standalone in the second half, and two only dates")
    }

    @Test func twoDifferentDatesInOneTierGiveNone() {
        #expect(detect("01.11.2026\nDatum: 13.11.2026\nRechnungsdatum: 12.11.2026") == nil, "no fallback")
        #expect(detect("Datum: 13.11.2026\nRechnungsdatum: 13. November 2026") == Self.november13, "the same date")
        #expect(detect("13.11.2026\n12.11.2026\nText\nText") == nil)
    }

    @Test func onlyFourDigitYearsAndMonthNamesCountAsTheOnlyDate() {
        // N2: section and version numbers read as two-digit-year dates.
        #expect(detect("gemäß Ziffer 4.1.12 der Bedingungen") == nil)
        #expect(detect("Version 1.2.20 vom 13. November 2026") == Self.november13)
        #expect(detect("Ziffer 4.1.12 und Schreiben vom 13.11.2026") == Self.november13)
    }

    @Test func onlyTheFirstPageWithTextIsRead() {
        #expect(detect("\u{0C}  \n\u{0C}Datum: 13.11.2026\u{0C}Datum: 01.11.2026") == Self.november13)
        #expect(detect("Seite 1\u{0C}Datum: 13.11.2026") == nil)
        #expect(detect("") == nil)
    }

    // MARK: Fix round 1 of #204

    @Test func anAmbiguousInvalidOrImplausibleDateBlocksItsTier() {
        // B3: the form keeps its place in its tier, so no lower tier picks another date.
        #expect(detect("Date: 05/06/2026\nDear Mr. Smith,\nyour payment of 04/28/2026 was posted.") == nil, "D6")
        #expect(detect("Invoice Date: 05/06/2026\nPO Date: 04/28/2026") == nil, "D54")
        #expect(detect("Datum: 13.11.2028\nIhre Bestellung vom 01.11.2026") == nil, "D52")
        #expect(detect("Datum: 31.11.2026\nIhre Bestellung vom 01.11.2026") == nil, "D53")
        #expect(detect("05/06/2026\nIhre Bestellung vom 01.11.2026") == nil, "tier 2")
        #expect(detect("Rechnung vom 31.11.2026\nIhre Bestellung vom 01.11.2026") == nil, "tier 3: a full year")
        #expect(
            detect("Ziffer 31.11.26\nIhre Bestellung vom 01.11.2026") == date(1, 11, 2026), "tier 3: a two-digit year")
        #expect(detect("Datum: 13.11.2026\n05/06/2026") == Self.november13, "a higher tier still decides")
    }

    @Test func aCueOnThePreviousLineStopsADateThatEndsItsLine() {
        // N7: label above value, as Vision gives an info block.
        let birth = "Geburtsdatum\n05.03.1980\nKundennummer\n4711\nIhre Rechnung vom 13.11.2026"
        #expect(detect(birth) == Self.november13)
        #expect(detect("Fällig am\n27.11.2026\nRechnung vom 13.11.2026 über 100 EUR") == Self.november13)
        #expect(detect("Ihr Schreiben vom\n01.11.2026\n13.11.2026") == Self.november13)
        let joined = "John Smith Birth Date\n123 Main Street 03/05/1980\nStatement of November 13, 2026"
        #expect(detect(joined) == Self.november13)
        // A cue before the previous line's own date is used up there; a label at its end still labels.
        #expect(detect("Kündigung zum 31.12.2026\n13.11.2026") == Self.november13)
        let bezugszeichen = "Ihr Zeichen Ihre Nachricht vom Unser Zeichen Datum\nAB-1 01.11.2026 XY 13.11.2026"
        #expect(detect(bezugszeichen) == Self.november13)
    }

    /// DB1 of #204: a cue that is not at the previous line's end, or a date with its own label, stops nothing.
    @Test(arguments: [
        "Ihr Zeichen: AB-1\nDatum: 13.11.2026", "Your ref: 4711\nDate: 13 November 2026",
        "Termin: nach Vereinbarung\nDatum: 13.11.2026", "Bitte antworten Sie bis Ende des Monats.\nMünchen, 13.11.2026",
        "Eingang\nRechnungsdatum 13.11.2026", "Ihr Zeichen: AB-1\n13.11.2026",
        "Thank you, the balance is due on receipt.\nNovember 13, 2026",
    ])
    func aCueOnlyAtThePreviousLinesEndStopsAnUnlabelledDate(text: String) {
        #expect(detect(text) == Self.november13, "\(text)")
    }

    /// Both dates are standalone in the first half; only the cue at the previous line's end leaves one.
    @Test func aCueWithAPrepositionOrColonAtTheLineEndStops() {
        #expect(detect("13.11.2026\nZahlbar bis:\n27.11.2026\nText\nText\nText") == Self.november13)
        #expect(detect("13.11.2026\nPayable by\nNovember 27, 2026\nText\nText\nText") == Self.november13)
        #expect(detect("13.11.2026\nGeburtsdatum:\n05.03.1980\nText\nText\nText") == Self.november13)
    }

    @Test func aDayAndMonthWithoutAYearTakeNoPlace() {
        // DN3 of #204 (C4): `13.11.` alone or after a label is no date form and blocks no tier.
        #expect(detect("13.11.\nRechnung vom 13.11.2026") == Self.november13)
        #expect(detect("Datum: 13.11.\nRechnung vom 13.11.2026") == Self.november13)
    }

    @Test func aRelaxedPreviousLineLabelNeedsAPlainDatum() {
        // N8.
        let birth = "Max Mustermann Geb.-Datum\nMusterweg 2 05.03.1980\nRechnung vom 13.11.2026"
        #expect(detect(birth) == Self.november13)
        let payment = "John Smith Payment Date\n123 Main Street 11/28/2026\nStatement of November 13, 2026"
        #expect(detect(payment) == Self.november13)
        #expect(detect("Liefer-Datum: 10.11.2026\nRechnung vom 13.11.2026") == Self.november13)
        #expect(detect("01.11.2026\nRechnungs-Datum: 13.11.2026") == Self.november13, "a joined label still counts")
    }

    @Test func aSuffixCueEndsAWordButIsNoWordPart() {
        // N9: `Spende` ends with `ende`, which is no suffix cue; `Terminal` holds `termin` inside a word.
        #expect(detect("Ihre Spende vom 13.11.2026") == Self.november13)
        #expect(detect("Terminal 2, Ankunft 13.11.2026") == Self.november13)
    }

    @Test func aPersonsNameIsNoPlace() {
        // N10.
        #expect(detect("01.11.2026\nMax Mustermann, 05.03.1980") == date(1, 11, 2026))
        #expect(detect("01.11.2026\nBad Homburg, 13.11.2026") == Self.november13)
        #expect(detect("01.11.2026\nNew York, November 13, 2026") == Self.november13)
        #expect(detect("01.11.2026\nMünchen, 13.11.2026") == Self.november13)
    }

    @Test func standaloneAndLineEndsAllowTrailingPunctuation() {
        // N11: M1, a standalone date followed by `,`; M2, a line that ends with the date and `.`.
        #expect(detect("13.11.2026,\nUnsere Nachricht vom 01.11.2026") == Self.november13)
        #expect(detect("01.11.2026\nMax Mustermann Datum\nMusterweg 2 13.11.2026.") == Self.november13)
    }

    // MARK: DateForms

    /// Every four-digit-year form `DateForms.forms(of:)` produces parses back to its date.
    @Test func everyFourDigitFormOfDateFormsParsesBack() {
        var random = TestRandom(seed: 0x11_DA7E)
        let late = Date(timeIntervalSince1970: 4_102_444_800)  // 2100-01-01
        for _ in 0..<200 {
            let year = 1900 + random.below(200)
            let month = 1 + random.below(12)
            let day = 1 + random.below(28)
            let date = SuggestedDate(day: day, month: month, year: year)
            let forms = DateForms.forms(of: date).filter { $0.contains("\(year)") }
            #expect(forms.count >= 20)
            for form in forms {
                #expect(IssueDateDetector.detect(in: form, createdAt: late) == date, "\(form)")
            }
        }
    }
}
