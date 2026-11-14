import DokumentumKit
import Foundation
import Testing

/// Due dates from a letter's text (#12, part 2b; plan §5): the cues in German and English, the previous line, a bare
/// `bis`, ranges, numbers and codes, dates that are never due, the window and its two-digit years (review N4), the
/// order, the first five pages; and the suggestion rule (review B3) with the offer (maintainer decision Q2). Synthetic
/// text only.
struct DueDateDetectorTests {
    /// 2026-11-14 10:00 UTC.
    static let createdAt = SyntheticLetters.createdAt

    private func detect(_ text: String, createdAt: Date = createdAt) -> [DueDateCandidate] {
        DueDateDetector.candidates(in: text, createdAt: createdAt)
    }

    private static func day(_ stored: String) -> DeadlineDay {
        DeadlineDay(storedValue: stored)!
    }

    private func due(_ stored: String, _ kind: DueDateKind) -> DueDateCandidate {
        DueDateCandidate(day: Self.day(stored), kind: kind)
    }

    // MARK: Cues

    @Test(arguments: [
        ("Zahlbar bis 27.11.2026 ohne Abzug.", DueDateKind.payment),
        ("Der Betrag ist zahlbar am 27.11.2026.", .payment),
        ("zahlbar spätestens 27.11.2026", .payment),
        ("Zahlbar bis spätestens 27.11.2026", .payment),
        ("Der Betrag ist fällig am 27.11.2026.", .payment),
        ("Fällig bis 27. November 2026", .payment),
        ("fällig zum 27.11.2026", .payment),
        ("Fälligkeit: 27.11.2026", .payment),
        ("Fälligkeitsdatum 2026-11-27", .payment),
        ("Zahlungsziel: 27.11.2026", .payment),
        ("Kündigung bis zum 27.11.2026", .cancellation),
        ("Kündigung zum 27.11.2026 möglich", .cancellation),
        ("Der Vertrag ist kündbar bis 27.11.2026.", .cancellation),
        ("kündbar zum 27.11.2026", .cancellation),
        ("Kündigungsfrist: Kündigung bis zum 27.11.2026", .cancellation),
        ("Der Ausweis ist gültig bis 27.11.2026.", .expiry),
        ("Ablauf: 27.11.2026", .expiry),
        ("Ablaufdatum 27.11.2026", .expiry),
        ("Frist: 27.11.2026", .deadline),
        ("Einspruchsfrist bis 27.11.2026", .deadline),
        ("Bitte melden Sie sich spätestens am 27.11.2026.", .deadline),
        ("Rückmeldung bis 27.11.2026", .deadline),
        ("Abgabe bis 27.11.2026", .deadline),
        ("Die Unterlagen sind einzureichen bis 27.11.2026.", .deadline),
    ])
    func germanCues(text: String, kind: DueDateKind) {
        #expect(detect(text) == [due("2026-11-27", kind)], "\(text)")
    }

    @Test(arguments: [
        ("Due: November 27, 2026", DueDateKind.payment),
        ("Due Date: 27 November 2026", .payment),
        ("Payment due 2026-11-27", .payment),
        ("Payable by Nov 27, 2026", .payment),
        ("Please pay by 27/11/2026.", .payment),
        ("due by November 27th, 2026", .payment),
        ("Cancel by November 27, 2026", .cancellation),
        ("Your card expires 11/27/2026.", .expiry),
        ("Expiry date: 27 Nov 2026", .expiry),
        ("Expiration Date: November 27, 2026", .expiry),
        ("Valid until 27 November 2026", .expiry),
        ("Deadline: November 27, 2026", .deadline),
        ("Please respond by November 27, 2026.", .deadline),
        ("reply by 27 November 2026", .deadline),
        ("no later than November 27, 2026", .deadline),
    ])
    func englishCues(text: String, kind: DueDateKind) {
        #expect(detect(text) == [due("2026-11-27", kind)], "\(text)")
    }

    /// A date that ends its line, under a line that ends with a cue (optionally `:` and one preposition).
    @Test func aCueAtTheEndOfThePreviousLine() {
        #expect(detect("Fällig am\n27.11.2026") == [due("2026-11-27", .payment)])
        #expect(detect("Zahlbar bis zum:\n27.11.2026") == [due("2026-11-27", .payment)])
        #expect(detect("Payment due\nNovember 27, 2026") == [due("2026-11-27", .payment)])
        #expect(detect("Frist\n27.11.2026") == [due("2026-11-27", .deadline)])
        // Not when its own line labels it, not when it does not end its line, not two lines down.
        #expect(detect("Fällig am\nRechnungsdatum 27.11.2026").isEmpty)
        #expect(detect("Fällig am\n27.11.2026 und mehr").isEmpty)
        #expect(detect("Fällig am\n\nText\n27.11.2026").isEmpty)
        // A range split over two lines is no cue.
        #expect(detect("Leistungszeitraum 01.10.2026 bis\n31.10.2026").isEmpty)
    }

    /// A bare `bis` names a deadline when nothing more specific is there.
    @Test func aBareBis() {
        #expect(detect("Bitte überweisen Sie den Betrag bis 27.11.2026.") == [due("2026-11-27", .deadline)])
        #expect(detect("bis zum 27.11.2026") == [due("2026-11-27", .deadline)])
        #expect(detect("Zahlbar bis 27.11.2026") == [due("2026-11-27", .payment)], "the specific cue wins")
    }

    // MARK: Fix round 1 of #220 (review N1–N3, with the reviewer's probe lines)

    /// N1: a date its own label names as something else is never due, whatever cue stands earlier on its line.
    @Test(arguments: [
        "Zahlbar bis 14 Tage nach Rechnungsdatum 14.11.2026",
        "Zahlbar sofort, spätestens 7 Tage nach Rechnungsdatum 14.11.2026",
        "Payment due upon receipt. Invoice date: November 20, 2026",
        "Die Vollmacht gilt bis auf Weiteres, ausgestellt am 20.11.2026",
        "Kündigungsfrist: 3 Monate zum Monatsende. Vertragsbeginn: 01.12.2026",
        "Zahlbar bis spätestens nach dem Termin am 20.11.2026",
    ])
    func aDateItsOwnLabelNamesIsNeverDue(text: String) {
        #expect(detect(text).isEmpty, "\(text)")
    }

    /// N1 keeps the due dates beside such a label.
    @Test func aDueDateBesideAnotherLabelStillCounts() {
        #expect(detect("Rechnungsdatum: 14.11.2026  Fällig am: 28.11.2026") == [due("2026-11-28", .payment)])
        #expect(
            detect("Ihr Kind, geboren am 01.11.2026, ist bis 30.11.2026 anzumelden.")
                == [due("2026-11-30", .deadline)])
    }

    /// N2: a bare `bis` counts only right before the date.
    @Test(arguments: [
        "Bis auf Weiteres gelten die Preise ab 01.01.2027.", "Geöffnet von 8 bis 16 Uhr, Abholung 20.11.2026",
        "Sprechzeiten Montag bis Freitag, Ihr Termin am 20.11.2026",
    ])
    func aBareBisElsewhereOnTheLineIsNoCue(text: String) {
        #expect(detect(text).isEmpty, "\(text)")
    }

    @Test func aBareBisRightBeforeTheDateCounts() {
        #expect(
            detect("Zahlbar bis 28.11.2026 bzw. bis 05.12.2026 mit Mahngebühr")
                == [due("2026-11-28", .payment), due("2026-12-05", .deadline)])
        #expect(detect("Betrag bis zum 27.11.2026") == [due("2026-11-27", .deadline)])
    }

    /// N3: `Due to …` is no cue, and a place line under a cue line is no due date (as for the issue date).
    @Test func dueToAndAPlaceLineAreNoCues() {
        #expect(detect("Due to the move we write on November 28, 2026.").isEmpty)
        #expect(detect("Due to maintenance, our office is closed until November 28, 2026.").isEmpty)
        #expect(detect("Sie erreichen uns Montag bis\nFreitag. Hamburg, 20.11.2026").isEmpty)
        #expect(detect("Bitte zahlen Sie bis\nHamburg, 20.11.2026").isEmpty)
        #expect(detect("Bitte zahlen Sie bis\n20.11.2026") == [due("2026-11-20", .deadline)])
        #expect(detect("Payment due\nNovember 28, 2026") == [due("2026-11-28", .payment)])
    }

    // MARK: Never due

    @Test(arguments: [
        "Leistungszeitraum: 01.10.2026 – 31.10.2026", "Leistungszeitraum 01.10.–31.10.2026",
        "gültig vom 01.01. bis 31.12.2026", "gültig vom 01.01.2026 bis 31.12.2026", "valid 11/01/2026 to 11/30/2026",
        "Zeitraum 01.10.2026 - 31.10.2026, zahlbar",
    ])
    func rangesAreIgnored(text: String) {
        #expect(detect(text).isEmpty, "\(text)")
    }

    @Test func noDateInsideANumberOrCode() {
        #expect(detect("Fällig: RE-2026-11-27-001").isEmpty)
        #expect(detect("Zahlbar bis: Rechnung 127.11.2026").isEmpty)
        #expect(detect("Zahlbar bis: IBAN DE27 1120 2600 0000 0000 00").isEmpty)
        #expect(detect("Frist: Az. 27.11.2026-4").isEmpty)
    }

    @Test(arguments: [
        "Rechnungsdatum: 13.11.2026", "Datum: 27.11.2026", "Geburtsdatum: 05.03.1980",
        "Invoice Date: November 27, 2026",
        "Order Date: November 27, 2026", "München, den 27. November 2026", "Ihr Schreiben vom 27.11.2026",
        "Vertragsbeginn: 01.12.2026", "27.11.2026",
    ])
    func datesWithoutACueAreNeverDue(text: String) {
        #expect(detect(text).isEmpty, "\(text)")
    }

    @Test func noCueNoCandidate() {
        #expect(detect("Sehr geehrter Herr Mustermann,\nvielen Dank für Ihr Schreiben vom 13.11.2026.").isEmpty)
        #expect(detect("").isEmpty)
    }

    // MARK: Window and years

    /// From `createdAt` − 60 to + 1,095 days, as days in UTC: 2026-09-15 … 2029-11-13 for 2026-11-14.
    @Test func theWindowEnds() {
        #expect(detect("Frist: 2026-09-14").isEmpty, "−61 days")
        #expect(detect("Frist: 2026-09-15") == [due("2026-09-15", .deadline)], "−60 days")
        #expect(detect("Frist: 2029-11-13") == [due("2029-11-13", .deadline)], "+1,095 days")
        #expect(detect("Frist: 2029-11-14").isEmpty, "+1,096 days")
    }

    /// A two-digit year pivots on the window's last year (review N4): `28` is 2028 in a 2026 letter, `30` (after
    /// 2029) is 1930 and outside the window.
    @Test func twoDigitYearsPivotOnTheWindowsEnd() {
        #expect(detect("gültig bis 31.12.28") == [due("2028-12-31", .expiry)])
        #expect(detect("gültig bis 31.12.29").isEmpty, "2029, after the window's end")
        #expect(detect("gültig bis 01.01.29") == [due("2029-01-01", .expiry)])
        #expect(detect("gültig bis 01.01.30").isEmpty, "1930")
        #expect(detect("zahlbar bis 27.11.26") == [due("2026-11-27", .payment)])
    }

    // MARK: Result

    /// The candidates in day order with their kinds; one per day, the first in reading order giving the kind.
    @Test func candidatesInDayOrderWithTheirKinds() {
        let text = """
            Einspruchsfrist: bis 15.12.2026
            Zahlbar bis 27.11.2026, Rechnungsdatum 13.11.2026
            Kündigung zum 30.09.2027
            Frist 27.11.2026
            """
        #expect(
            detect(text) == [
                due("2026-11-27", .payment), due("2026-12-15", .deadline), due("2027-09-30", .cancellation),
            ])
    }

    /// Only the first five pages with text are read; empty pages do not count.
    @Test func fivePagesOnly() {
        let pages = (1...6).map { "Seite \($0)\nFrist: \(String(format: "%02d", $0)).12.2026" }
        let text = (["", "  "] + pages).joined(separator: "\u{0C}")
        #expect(detect(text).map(\.day.day) == [1, 2, 3, 4, 5])
    }

    // MARK: The suggestion (B3) and the offer (Q2)

    @Test func theSuggestionIsTheEarliestTodayOrLaterAfterTheDismissedDay() {
        let candidates = [due("2026-11-10", .payment), due("2026-11-27", .payment), due("2026-12-15", .deadline)]
        let today = Self.day("2026-11-14")
        let pick = { (dismissed: String?) in
            DueDateDetector.suggestion(among: candidates, today: today, dismissedThrough: dismissed.map(Self.day))
        }
        #expect(pick(nil) == candidates[1], "the past one is skipped")
        #expect(pick("2026-11-27") == candidates[2], "dismissed up to its day: the later one")
        #expect(pick("2026-12-15") == nil, "both dismissed: none")
        #expect(pick("2026-11-20") == candidates[1], "a later day than the dismissed one is offered")
        #expect(pick("2027-01-01") == nil, "an earlier day than the dismissed one is not")
        #expect(
            DueDateDetector.suggestion(among: candidates, today: Self.day("2026-11-27"), dismissedThrough: nil)
                == candidates[1], "due today is offered")
        #expect(DueDateDetector.suggestion(among: [], today: today, dismissedThrough: nil) == nil)
    }

    /// The tax notice of the corpus: one dismissal offers its later candidate, a second leaves none (B3).
    @Test func theTaxNoticeDismissedTwiceOffersNothing() throws {
        let letter = try #require(SyntheticLetters.letter("steuerbescheid-zwei-fristen"))
        let candidates = detect(letter.text, createdAt: letter.createdAt)
        let today = Self.day("2026-11-14")
        var dismissed: DeadlineDay?
        var offered: [DeadlineDay] = []
        for _ in 0..<3 {
            guard
                let suggestion = DueDateDetector.suggestion(
                    among: candidates, today: today, dismissedThrough: dismissed)
            else { break }
            offered.append(suggestion.day)
            dismissed = suggestion.day
        }
        #expect(offered == [Self.day("2026-11-27"), Self.day("2026-12-15")])
    }

    /// Offered only while the document has no deadline, is processed and not trashed, and the day is still ahead.
    @Test func theOfferNeedsNoDeadlineAProcessedDocumentAndADayAhead() {
        let today = Self.day("2026-11-14")
        let candidate = due("2026-11-27", .payment)
        func document(
            deadline: DocumentDeadline? = nil, state: ProcessingState = .done, deletedAt: Date? = nil,
            dismissed: String? = nil
        ) -> LibraryDocument {
            LibraryDocument(
                instanceID: UUID(), title: "Rechnung", documentDate: Self.createdAt, createdAt: Self.createdAt,
                isInbox: true, deletedAt: deletedAt, processingState: state, deadline: deadline,
                dismissedSuggestionDay: dismissed.map(Self.day))
        }
        #expect(DueDateDetector.offers(candidate, for: document(), today: today))
        #expect(!DueDateDetector.offers(candidate, for: document(deadline: .init(day: candidate.day)), today: today))
        #expect(
            !DueDateDetector.offers(
                candidate, for: document(deadline: .init(day: Self.day("2026-12-01"), doneAt: Self.createdAt)),
                today: today), "a done deadline is a deadline")
        for state in ProcessingState.allCases where state != .done {
            #expect(!DueDateDetector.offers(candidate, for: document(state: state), today: today), "\(state)")
        }
        #expect(!DueDateDetector.offers(candidate, for: document(deletedAt: Self.createdAt), today: today))
        #expect(!DueDateDetector.offers(candidate, for: document(dismissed: "2026-11-27"), today: today))
        #expect(DueDateDetector.offers(candidate, for: document(dismissed: "2026-11-26"), today: today))
        #expect(!DueDateDetector.offers(candidate, for: document(), today: Self.day("2026-11-28")))
    }
}
