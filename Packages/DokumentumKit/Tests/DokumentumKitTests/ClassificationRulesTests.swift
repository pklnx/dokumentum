import DokumentumKit
import Foundation
import Testing

/// The Kit rules of the classification step (#8, part 1): the checks of a suggestion, the name matcher, the
/// emptiness of fields and the wait for a model that is not ready.
struct SuggestionRulesTests {
    static let now = Date(timeIntervalSince1970: 1_780_000_000)  // 2026-05-28
    static let bill = """
        Stadtwerke München GmbH · Emmy-Noether-Straße 2 · 80992 München
        Jahresabrechnung Strom 2025
        München, 14.01.2026
        Sehr geehrte Frau Muster, anbei Ihre Abrechnung.
        """

    private func check(_ suggestion: ClassificationSuggestion, text: String = bill) -> CheckedSuggestion {
        SuggestionRules.check(suggestion, text: text, now: Self.now)
    }

    // MARK: Title

    @Test func aTitleIsTrimmedAndKept() {
        #expect(check(.init(title: "  Jahresabrechnung Strom \n")).title == "Jahresabrechnung Strom")
    }

    @Test(arguments: ["", "   ", "Unbekannt", "unknown", "N/A", "-", "keine", "None"])
    func anEmptyOrPlaceholderTitleIsDropped(title: String) {
        #expect(check(.init(title: title)).title == nil)
    }

    @Test func aLongTitleIsCutAtAWord() {
        let words = Array(repeating: "Abrechnung", count: 10).joined(separator: " ")  // 109 characters
        let cut = check(.init(title: words)).title
        #expect(cut == Array(repeating: "Abrechnung", count: 7).joined(separator: " "))
        #expect((cut?.count ?? 0) <= 80)
        let exact = String(repeating: "a", count: 40) + " " + String(repeating: "b", count: 39)
        #expect(check(.init(title: exact)).title == exact, "80 characters stay")
        let oneWord = String(repeating: "x", count: 90)
        #expect(check(.init(title: oneWord)).title == String(repeating: "x", count: 80))
        let wordEndsAt80 = String(repeating: "a", count: 80) + " tail"
        #expect(check(.init(title: wordEndsAt80)).title == String(repeating: "a", count: 80))
    }

    // MARK: Correspondent

    @Test func aCorrespondentInTheTextIsKept() {
        #expect(check(.init(correspondent: "Stadtwerke München GmbH")).correspondent == "Stadtwerke München GmbH")
        #expect(check(.init(correspondent: "stadtwerke munchen")).correspondent == "stadtwerke munchen", "folded")
        #expect(check(.init(correspondent: "Stadtwerke   München")).correspondent != nil, "whitespace collapsed")
    }

    @Test func anInventedCorrespondentIsDropped() {
        #expect(check(.init(correspondent: "Unklar Versicherung AG")).correspondent == nil)
        #expect(check(.init(correspondent: "Stadtwerke Berlin")).correspondent == nil)
        #expect(check(.init(correspondent: "Stadt")).correspondent == nil, "only whole words")
        #expect(check(.init(correspondent: "Stadtwerke"), text: "Seite 1").correspondent == nil)
    }

    @Test func aPlaceholderOrLongCorrespondentIsDropped() {
        #expect(check(.init(correspondent: "Unbekannt"), text: "Absender unbekannt").correspondent == nil)
        let long = String(repeating: "Gesellschaft ", count: 7)  // 91 characters
        #expect(check(.init(correspondent: long), text: long).correspondent == nil)
    }

    // MARK: Type

    @Test func aTypeWithinItsLimitsIsKept() {
        #expect(check(.init(documentType: "Abrechnung")).documentType == "Abrechnung")
        #expect(check(.init(documentType: "Bescheid über Grundsteuer")).documentType != nil, "3 words")
        #expect(check(.init(documentType: "Ein Bescheid über Grundsteuer")).documentType == nil, "4 words")
        #expect(check(.init(documentType: String(repeating: "x", count: 41))).documentType == nil)
        #expect(check(.init(documentType: "unklar")).documentType == nil)
    }

    // MARK: Tags

    @Test func tagsAreTrimmedDeduplicatedAndCappedAtThree() {
        let tags = check(.init(tags: [" Strom ", "strom", "Nebenkosten", "", "Haus", "Steuer"])).tags
        #expect(tags == ["Strom", "Nebenkosten", "Haus"])
    }

    // MARK: Date

    @Test(arguments: [
        "14.01.2026", "14.1.2026", "14.1.26", "14.01.26", "2026-01-14", "14. Januar 2026", "14. Jänner 2026",
        "14 Januar 2026", "14.Januar 2026", "14 January 2026", "January 14, 2026", "January 14 2026",
        "14. Jan. 2026", "Datum: 14. JANUAR 2026",
    ])
    func aDateInTheTextIsKept(form: String) {
        let date = SuggestedDate(day: 14, month: 1, year: 2026)
        #expect(check(.init(issueDate: date), text: "Rechnung vom \(form) für Strom").issueDate == date, "\(form)")
    }

    @Test func otherMonthNamesInBothLanguages() {
        #expect(DateForms.occurs(.init(day: 2, month: 3, year: 2026), in: "am 2. März 2026"))
        #expect(DateForms.occurs(.init(day: 2, month: 3, year: 2026), in: "2 March 2026"))
        #expect(DateForms.occurs(.init(day: 30, month: 6, year: 2025), in: "vom 30.06.2025"))
        #expect(DateForms.occurs(.init(day: 1, month: 12, year: 2025), in: "December 1, 2025"))
        #expect(DateForms.occurs(.init(day: 1, month: 12, year: 2025), in: "1. Dezember 2025"))
        #expect(DateForms.occurs(.init(day: 31, month: 10, year: 2025), in: "31. Oktober 2025"))
    }

    @Test func aDateNotInTheTextIsDropped() {
        // P-j: "2 March 2026" read as 2026-02-03; "30.06.2025" read as 2024-06-30.
        #expect(!DateForms.occurs(.init(day: 3, month: 2, year: 2026), in: "2 March 2026"))
        #expect(!DateForms.occurs(.init(day: 30, month: 6, year: 2024), in: "vom 30.06.2025"))
        #expect(!DateForms.occurs(.init(day: 4, month: 1, year: 2026), in: "14.01.2026"), "never inside a number")
        #expect(!DateForms.occurs(.init(day: 14, month: 1, year: 2026), in: "114.01.2026"))
        #expect(!DateForms.occurs(.init(day: 14, month: 1, year: 2020), in: "14.01.2026"))
        #expect(check(.init(issueDate: .init(day: 1, month: 1, year: 1900)), text: "Seite 1").issueDate == nil)
    }

    @Test func anImpossibleOrOutOfRangeDateIsDropped() {
        for (day, month, year) in [
            (30, 2, 2026), (31, 4, 2026), (0, 1, 2026), (1, 13, 2026), (1, 1, 1899), (1, 1, 2028),
        ] {
            let date = SuggestedDate(day: day, month: month, year: year)
            let text = "Datum \(day).\(month).\(year) und \(year)-\(month)-\(day)"
            #expect(check(.init(issueDate: date), text: text).issueDate == nil, "\(date)")
        }
        // Next year is still in range (a document dated ahead), the year after is not.
        let next = SuggestedDate(day: 2, month: 1, year: 2027)
        #expect(check(.init(issueDate: next), text: "fällig am 02.01.2027").issueDate == next)
        let leap = SuggestedDate(day: 29, month: 2, year: 2024)
        #expect(check(.init(issueDate: leap), text: "29.02.2024").issueDate == leap)
    }

    @Test func eachFieldIsCheckedOnItsOwn() {
        let checked = check(
            .init(
                title: "Jahresabrechnung Strom", correspondent: "Erfunden GmbH", documentType: "Abrechnung",
                tags: ["Strom"], issueDate: .init(day: 15, month: 1, year: 2026)))
        #expect(
            checked
                == CheckedSuggestion(title: "Jahresabrechnung Strom", documentType: "Abrechnung", tags: ["Strom"]))
    }
}

struct MetadataMatcherTests {
    static let ids = (0..<6).map { _ in UUID() }

    private func records(_ names: [String]) -> [MetadataMatcher.Record] {
        names.enumerated().map { MetadataMatcher.Record(id: Self.ids[$0.offset], name: $0.element) }
    }

    @Test func anEqualNameMatchesTheFirstInKeeperOrder() {
        let known = records(["Stadtwerke München", "stadtwerke munchen ", "Amazon"])
        #expect(MetadataMatcher.match("STADTWERKE MÜNCHEN", among: known) == Self.ids[0])
    }

    @Test func aPrefixMatchesBothWays() {
        let known = records(["Amazon", "Hausverwaltung Berger"])
        #expect(MetadataMatcher.match("Amazon EU S.à r.l.", among: known) == Self.ids[0])
        #expect(MetadataMatcher.match("Hausverwaltung Berger & Söhne KG", among: known) == Self.ids[1])
        let long = records(["Stadtwerke München GmbH"])
        #expect(MetadataMatcher.match("Stadtwerke München", among: long) == Self.ids[0])
    }

    @Test func onlyWholeWordsArePrefixes() {
        let known = records(["Amazon"])
        #expect(MetadataMatcher.match("Amazonas Reisen", among: known) == nil)
        #expect(MetadataMatcher.match("Allianz", among: known) == nil)
    }

    @Test func theLongestPrefixWinsAndATieMatchesNone() {
        let known = records(["Stadtwerke", "Stadtwerke München", "Stadtwerke Berlin"])
        #expect(MetadataMatcher.match("Stadtwerke München GmbH", among: known) == Self.ids[1])
        // "Stadtwerke" is a prefix of all three; "Stadtwerke München" and "Stadtwerke Berlin" both start with it
        // and have two words each: a tie.
        #expect(MetadataMatcher.match("Stadtwerke", among: known) == Self.ids[0], "equal wins first")
        let tie = records(["Stadtwerke München", "Stadtwerke Berlin"])
        #expect(MetadataMatcher.match("Stadtwerke", among: tie) == nil)
    }

    @Test func nothingMatchesAnEmptyName() {
        #expect(MetadataMatcher.match("  ", among: records(["A"])) == nil)
        #expect(MetadataMatcher.match("Neu", among: []) == nil)
    }

    /// N7: two live tags with the same name (different parents) make the name ambiguous: none is linked.
    @Test func aTagMatchesOnlyOneEqualName() {
        let tags = records(["Strom", "Steuer", "steuer", "Haus"])
        #expect(MetadataMatcher.tag("STROM", among: tags) == Self.ids[0])
        #expect(MetadataMatcher.tag("Steuer", among: tags) == nil, "ambiguous")
        #expect(MetadataMatcher.tag("Hausrat", among: tags) == nil, "never a prefix")
        #expect(MetadataMatcher.tag("Garten", among: tags) == nil)
    }
}

struct ClassificationFieldsTests {
    static let created = Date(timeIntervalSince1970: 1_780_000_000)

    private func fields(
        title: String = "Scan 2026-05-28", modified: Date = created, date: Date = created,
        correspondent: Bool = false, type: Bool = false, tags: Bool = false
    ) -> ClassificationFields {
        ClassificationFields(
            title: title, createdAt: Self.created, modifiedAt: modified, documentDate: date,
            hasCorrespondent: correspondent, hasDocumentType: type, hasTags: tags)
    }

    @Test func aNeverEditedDocumentHasEveryFieldEmpty() {
        let fields = fields()
        #expect(fields.isNeverEdited)
        #expect(fields.titleIsEmpty && fields.dateIsEmpty)
        #expect(fields.correspondentIsEmpty && fields.documentTypeIsEmpty && fields.tagsAreEmpty)
    }

    @Test func anEditKeepsTitleAndDate() {
        let edited = fields(modified: Self.created.addingTimeInterval(1))
        #expect(!edited.titleIsEmpty)
        #expect(!edited.dateIsEmpty)
        #expect(edited.correspondentIsEmpty, "by value")
    }

    @Test func anEmptyTitleIsEmptyAfterAnEdit() {
        #expect(fields(title: "  ", modified: Self.created.addingTimeInterval(1)).titleIsEmpty)
    }

    @Test func aDateOtherThanTheImportTimeIsKept() {
        // Not reachable through the editor without a touch, but the rule needs both.
        #expect(!fields(date: Self.created.addingTimeInterval(-86_400)).dateIsEmpty)
        #expect(fields(date: Self.created.addingTimeInterval(-86_400)).titleIsEmpty)
    }

    @Test func setValuesAreNotEmpty() {
        let set = fields(correspondent: true, type: true, tags: true)
        #expect(!set.correspondentIsEmpty && !set.documentTypeIsEmpty && !set.tagsAreEmpty)
    }

    @Test func theStoredDateKeepsTheTimeOfDayAsThePickerDoes() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Europe/Berlin"))
        let keeping = try #require(
            calendar.date(from: DateComponents(year: 2026, month: 5, day: 28, hour: 21, minute: 7, second: 3)))
        let stored = try #require(
            ClassificationFields.storedDate(
                .init(day: 14, month: 1, year: 2026), keepingTimeOf: keeping, calendar: calendar))
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: stored)
        #expect(parts == DateComponents(year: 2026, month: 1, day: 14, hour: 21, minute: 7, second: 3))
        #expect(
            ClassificationFields.storedDate(
                .init(day: 31, month: 2, year: 2026), keepingTimeOf: keeping, calendar: calendar)
                == nil)
    }
}

/// N4: the wait for a model that is not ready ends when this device's own claim is stale, and that check comes
/// before the renewal `ProcessingClaimRules.decide` would make.
struct ClassificationWaitTests {
    static let now = Date(timeIntervalSince1970: 2_000_000_000)
    static let interval = ProcessingClaimRules.takeoverInterval

    @Test func aFreshOwnClaimWaitsUntilItExpires() {
        let claimed = Self.now.addingTimeInterval(-3600)
        #expect(
            ClassificationWait.decide(deviceID: "A", claimedAt: claimed, thisDevice: "A", now: Self.now)
                == .wait(until: claimed.addingTimeInterval(Self.interval)))
    }

    @Test func aStaleOwnClaimFinishesWhereTheRulesWouldRenewIt() {
        let claimed = Self.now.addingTimeInterval(-Self.interval)
        let input = ProcessingClaimInput(state: .classify, deviceID: "A", claimedAt: claimed)
        #expect(ProcessingClaimRules.decide(input, thisDevice: "A", failures: 0, now: Self.now) == .process(.claim))
        #expect(ClassificationWait.decide(deviceID: "A", claimedAt: claimed, thisDevice: "A", now: Self.now) == .finish)
        let future = Self.now.addingTimeInterval(Self.interval + 1)
        #expect(ClassificationWait.decide(deviceID: "A", claimedAt: future, thisDevice: "A", now: Self.now) == .finish)
    }

    @Test func noOwnClaimIsClaimedToStartTheWait() {
        #expect(
            ClassificationWait.decide(deviceID: "", claimedAt: nil, thisDevice: "A", now: Self.now) == .claimAndWait)
        #expect(
            ClassificationWait.decide(
                deviceID: "B", claimedAt: Self.now.addingTimeInterval(-7 * 3600), thisDevice: "A", now: Self.now)
                == .claimAndWait)
    }
}
