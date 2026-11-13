import Foundation

/// The issue date of a letter, from its text only (plan of #11, Approach 2). Text only, so the classification step
/// can compute the same result again from the stored text and `createdAt` (part 2).
///
/// **Input:** the first page with text (the stored text split at form feeds), as lines, and the document's
/// `createdAt`. Every line is folded as `SuggestionRules.fold` folds (case, diacritics, `ß`, whitespace).
///
/// **Forms** (never inside a longer number or code such as `RE-2026-11-13-001`):
/// - numeric with dots: `13.11.2026`, `13.11.26`, `3.1.2026`, `13. 11. 2026`;
/// - month names (`MonthNames`, German and English): `13. November 2026`, `13 November 2026`, `13. Nov. 2026`,
///   `13.Nov.2026`, `13th November 2026`, `13-Nov-2026`, `November 13, 2026`, `November 13th, 2026`, `Nov 13, 2026`;
/// - ISO `2026-11-13`;
/// - slashes only when unambiguous: `13/11/2026` or `11/13/2026`; `05/06/2026` is ignored.
///
/// A two-digit year is `20yy`, unless that is after `createdAt`'s year + 1; then it is `19yy`.
///
/// **Plausible:** a valid Gregorian date from 1900-01-01 to `createdAt` + 31 days (`DetectionLimits.dateWindowDays`).
///
/// **Ignored:** a date with a cue (`germanCues`, `englishCues`; both apply to every document) between the previous
/// date of its line (or the line's start) and itself, and both dates of a range (`01.10.2026 – 31.10.2026`,
/// `01.10.–31.10.2026`, `… bis …`, `… to …`).
///
/// **Tiers** (the first non-empty tier decides; two different dates in it give none, with no fallback):
/// 1. *labelled*: a label directly before the date on its line (colon optional): `labels`, or `Datum`/`Date` with
///    no letter word directly before it (`Musterweg 2 Datum: …` counts, `Order Date: …` does not, N1, N3). A label at
///    the end of the previous line counts when the date ends its own line and that line does not end with a cue
///    (`Max Mustermann Datum` / `Musterweg 2 13.11.2026`, N3). A place line counts too: one to three words, a comma,
///    an optional `den`, the date and nothing after it (`München, den 13.11.2026`);
/// 2. *standalone*: a line that is only the date, in the first half of the page's lines;
/// 3. *only*: exactly one distinct date with a four-digit year or a month name (N2: `Ziffer 4.1.12` never counts).
public enum IssueDateDetector {
    /// Due and payment, birth, periods, validity, compound date labels (N1), other letters and events, form versions.
    public static let germanCues = [
        "fällig", "Fälligkeit", "Fälligkeitsdatum", "zahlbar", "Zahlungsziel", "spätestens", "bis",
        "Geburtsdatum", "geb.", "geboren",
        "Zeitraum", "Leistungszeitraum", "Abrechnungszeitraum",
        "gültig", "Laufzeit", "Beginn", "Ende", "Vertragsbeginn", "Kündigung", "Frist",
        "Datum der Leistung", "Lieferdatum", "Leistungsdatum", "Bestelldatum",
        "Ihr Schreiben", "Ihre Nachricht", "Ihr Zeichen", "Eingang", "Termin",
        "Stand",
    ]
    public static let englishCues = [
        "due", "payable", "pay by",
        "date of birth", "DOB", "born",
        "period",
        "valid", "expires", "until", "deadline",
        "Order Date", "Start Date", "End Date", "Ship Date", "Shipping Date", "Effective Date", "Delivery Date",
        "Service Date", "Due Date",
        "your letter", "your ref", "received", "appointment",
    ]
    /// The labels of tier 1 besides `Datum` and `Date`.
    public static let labels = [
        "Rechnungsdatum", "Belegdatum", "Ausstellungsdatum", "ausgestellt am", "erstellt am", "Bescheiddatum",
        "Invoice date", "Issue date", "Date of issue", "Issued on", "Issued", "Statement date", "Dated",
    ]
    /// `Datum` and `Date`: labels only with no letter word directly before them (N1).
    static let plainLabels = ["datum", "date"]
    /// What joins the two dates of a range.
    static let rangeConnectors: Set<String> = [
        "bis", "bis zum", "bis zur", "-", "–", "—", "to", "until", "till", "through", "thru",
    ]

    static let foldedCues = (germanCues + englishCues).map(SuggestionRules.fold)
    static let foldedLabels = labels.map(SuggestionRules.fold)

    /// Gregorian, UTC: the calendar the window and the two-digit years are computed in when none is given.
    public static var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? calendar.timeZone
        return calendar
    }

    /// The issue date in a document's text: its first page with text is read.
    public static func detect(in text: String, createdAt: Date, calendar: Calendar = utcCalendar) -> SuggestedDate? {
        let page = text.split(separator: "\u{0C}", omittingEmptySubsequences: false)
            .first { !$0.allSatisfy(\.isWhitespace) }
        guard let page else { return nil }
        return detect(
            lines: page.split(whereSeparator: \.isNewline).map(String.init), createdAt: createdAt,
            calendar: calendar)
    }

    /// The issue date in one page's lines.
    public static func detect(lines: [String], createdAt: Date, calendar: Calendar = utcCalendar) -> SuggestedDate? {
        let folded = lines.map(SuggestionRules.fold).filter { !$0.isEmpty }
        let window = Window(createdAt: createdAt, calendar: calendar)
        var labelled: [SuggestedDate] = []
        var standalone: [SuggestedDate] = []
        var strong: [SuggestedDate] = []
        let firstHalf = (folded.count + 1) / 2
        for (index, line) in folded.enumerated() {
            let characters = Array(line)
            let tokens = Token.split(characters)
            let found = DateScanner(tokens: tokens, window: window).scan()
            for (position, item) in found.enumerated() {
                guard let date = item.date, window.contains(date) else { continue }
                let before = String(characters[0..<item.start])
                let after = String(characters[item.end...]).trimmingCharacters(in: .whitespaces)
                let segmentStart = position > 0 ? found[position - 1].end : 0
                let segment = String(characters[segmentStart..<item.start])
                if isRange(found, at: position, in: characters) || hasCue(segment) { continue }
                let endsLine = after.isEmpty || after == "."
                let previous = index > 0 ? folded[index - 1] : nil
                if endsWithLabel(before, strict: true) || (endsLine && isPlaceLine(before))
                    || (endsLine && previous.map(labelsNextLine) == true)
                {
                    labelled.append(date)
                } else if before.allSatisfy(\.isWhitespace), endsLine || after == ",", index < firstHalf {
                    standalone.append(date)
                }
                if item.isStrong { strong.append(date) }
            }
        }
        for tier in [labelled, standalone, strong] where !tier.isEmpty {
            return Set(tier).count == 1 ? tier[0] : nil
        }
        return nil
    }

    // MARK: Cues and labels

    /// Whether the folded text holds a cue as whole words.
    static func hasCue(_ folded: String) -> Bool {
        foldedCues.contains { Folded.containsBounded($0, in: folded) }
    }

    /// Whether the dates at `position` and next to it form a range: only a connector between them.
    static func isRange(_ found: [DateScanner.Found], at position: Int, in characters: [Character]) -> Bool {
        func joined(_ first: Int, _ second: Int) -> Bool {
            let between = String(characters[found[first].end..<found[second].start])
                .trimmingCharacters(in: .whitespaces)
            return rangeConnectors.contains(between)
        }
        return (position > 0 && joined(position - 1, position))
            || (position + 1 < found.count && joined(position, position + 1))
    }

    /// Whether the folded text before a date ends with a label (colon optional). `strict`: `Datum`/`Date` count
    /// only with no letter word directly before them.
    static func endsWithLabel(_ before: String, strict: Bool) -> Bool {
        var text = Substring(before).trimmingSuffix(\.isWhitespace)
        if text.last == ":" { text = text.dropLast().trimmingSuffix(\.isWhitespace) }
        for label in foldedLabels where endsWithWord(text, label) { return true }
        for label in plainLabels where endsWithWord(text, label) {
            guard strict else { return true }
            let rest = text.dropLast(label.count).trimmingSuffix(\.isWhitespace)
            if let last = rest.last, last.isLetter { continue }
            return true
        }
        return false
    }

    /// Whether a line's label applies to a date that ends the next line (N3): it ends with a label and not with a
    /// cue (`Order Date`).
    static func labelsNextLine(_ line: String) -> Bool {
        var text = Substring(line).trimmingSuffix(\.isWhitespace)
        if text.last == ":" { text = text.dropLast().trimmingSuffix(\.isWhitespace) }
        guard !foldedCues.contains(where: { endsWithWord(text, $0) }) else { return false }
        return endsWithLabel(String(text), strict: false)
    }

    /// `München, den` / `London,`: one to three words, a comma, an optional `den`.
    static func isPlaceLine(_ before: String) -> Bool {
        var text = Substring(before).trimmingSuffix(\.isWhitespace)
        if text.hasSuffix(" den") { text = text.dropLast(4).trimmingSuffix(\.isWhitespace) }
        guard text.last == "," else { return false }
        let words = text.dropLast().split(separator: " ")
        return (1...3).contains(words.count)
            && words.allSatisfy { word in
                word.contains(where: \.isLetter) && word.allSatisfy { $0.isLetter || $0 == "-" || $0 == "." }
            }
    }

    /// Whether `text` ends with `word`, with no letter or digit right before it.
    static func endsWithWord(_ text: Substring, _ word: String) -> Bool {
        guard text.hasSuffix(word) else { return false }
        let head = text.dropLast(word.count)
        guard let last = head.last else { return true }
        return !(last.isLetter || last.isNumber)
    }
}

extension Substring {
    fileprivate func trimmingSuffix(_ predicate: (Character) -> Bool) -> Substring {
        var result = self
        while let last = result.last, predicate(last) { result = result.dropLast() }
        return result
    }
}

/// The dates the detector accepts: valid, from 1900-01-01 to `createdAt` + 31 days.
struct Window {
    let earliest = SuggestedDate(day: 1, month: 1, year: DetectionLimits.earliestYear)
    let latest: SuggestedDate
    /// `createdAt`'s year, for the two-digit years.
    let createdYear: Int

    init(createdAt: Date, calendar: Calendar) {
        let end = calendar.date(byAdding: .day, value: DetectionLimits.dateWindowDays, to: createdAt) ?? createdAt
        let parts = calendar.dateComponents([.year, .month, .day], from: end)
        latest = SuggestedDate(day: parts.day ?? 1, month: parts.month ?? 1, year: parts.year ?? 1)
        createdYear = calendar.component(.year, from: createdAt)
    }

    func contains(_ date: SuggestedDate) -> Bool {
        let key = (date.year, date.month, date.day)
        return key >= (earliest.year, earliest.month, earliest.day) && key <= (latest.year, latest.month, latest.day)
    }

    /// A two-digit year as a full year (`20yy`, or `19yy` when `20yy` is after `createdAt`'s year + 1).
    func fullYear(twoDigit year: Int) -> Int {
        2000 + year > createdYear + 1 ? 1900 + year : 2000 + year
    }
}

/// A run of digits, of letters, or one other character of a folded line, with its place.
struct Token {
    enum Kind { case number, word, symbol }

    let kind: Kind
    let text: String
    /// Character offsets in the line: `start..<end`.
    let start: Int
    let end: Int
    /// Whether whitespace comes right before it.
    let spaced: Bool

    static func split(_ characters: [Character]) -> [Token] {
        var tokens: [Token] = []
        var index = 0
        var spaced = false
        while index < characters.count {
            let character = characters[index]
            if character.isWhitespace {
                spaced = true
                index += 1
                continue
            }
            let kind: Kind = isDigit(character) ? .number : character.isLetter ? .word : .symbol
            var end = index + 1
            if kind != .symbol {
                while end < characters.count, kind == .number ? isDigit(characters[end]) : characters[end].isLetter {
                    end += 1
                }
            }
            tokens.append(
                Token(kind: kind, text: String(characters[index..<end]), start: index, end: end, spaced: spaced))
            spaced = false
            index = end
        }
        return tokens
    }

    static func isDigit(_ character: Character) -> Bool {
        character.isASCII && character.isNumber
    }

    func isNumber(digits: ClosedRange<Int>) -> Bool {
        kind == .number && digits.contains(text.count)
    }

    func isSymbol(_ symbol: String) -> Bool {
        kind == .symbol && text == symbol
    }
}

/// Finds the date forms in one line's tokens.
struct DateScanner {
    /// A form found: a valid date, or `nil` for a day and month without a year (`01.10.` of a range), an ambiguous
    /// slash date or an invalid date (`30.02.2026`). Every form counts for ranges.
    struct Found {
        var date: SuggestedDate?
        /// Character offsets in the line.
        var start: Int
        var end: Int
        /// A four-digit year or a month name (tier 3, N2).
        var isStrong: Bool
    }

    let tokens: [Token]
    let window: Window

    func scan() -> [Found] {
        var found: [Found] = []
        var index = 0
        while index < tokens.count {
            if let (last, item) = match(at: index) {
                found.append(item)
                index = last + 1
            } else {
                index += 1
            }
        }
        return found
    }

    private func token(_ index: Int) -> Token? {
        index < tokens.count ? tokens[index] : nil
    }

    /// The form starting at `index`: its last token and what it says.
    private func match(at index: Int) -> (Int, Found)? {
        let forms: [(Int) -> (last: Int, day: Int, month: Int, year: Int, strong: Bool, valid: Bool)?] = [
            iso, dotted, slashed, dayMonthName, monthNameDay,
        ]
        for form in forms {
            guard let result = form(index), isBounded(first: index, last: result.last) else { continue }
            var item = Found(
                date: nil, start: tokens[index].start, end: tokens[result.last].end, isStrong: result.strong)
            if result.valid, Self.isValid(day: result.day, month: result.month, year: result.year) {
                item.date = SuggestedDate(day: result.day, month: result.month, year: result.year)
            }
            return (result.last, item)
        }
        if let last = dayMonthOnly(index) {
            return (last, Found(date: nil, start: tokens[index].start, end: tokens[last].end, isStrong: false))
        }
        return nil
    }

    /// Not inside a longer number or code: no letter, digit, `-`, `.` or `/` touching the start; no letter or
    /// digit touching the end, and no `-`, `.` or `/` followed by a digit.
    private func isBounded(first: Int, last: Int) -> Bool {
        if first > 0, !tokens[first].spaced {
            let previous = tokens[first - 1]
            if previous.kind != .symbol || ["-", ".", "/"].contains(previous.text) { return false }
        }
        if let next = token(last + 1), !next.spaced {
            if next.kind != .symbol { return false }
            if ["-", ".", "/"].contains(next.text), let after = token(last + 2), !after.spaced, after.kind == .number {
                return false
            }
        }
        return true
    }

    /// `2026-11-13`.
    private func iso(_ index: Int) -> (last: Int, day: Int, month: Int, year: Int, strong: Bool, valid: Bool)? {
        guard let year = token(index), year.isNumber(digits: 4...4),
            let dash1 = token(index + 1), dash1.isSymbol("-"), !dash1.spaced,
            let month = token(index + 2), month.isNumber(digits: 1...2), !month.spaced,
            let dash2 = token(index + 3), dash2.isSymbol("-"), !dash2.spaced,
            let day = token(index + 4), day.isNumber(digits: 1...2), !day.spaced
        else { return nil }
        return (index + 4, Int(day.text) ?? 0, Int(month.text) ?? 0, Int(year.text) ?? 0, true, true)
    }

    /// `13.11.2026`, `13.11.26`, `13. 11. 2026`.
    private func dotted(_ index: Int) -> (last: Int, day: Int, month: Int, year: Int, strong: Bool, valid: Bool)? {
        guard let day = token(index), day.isNumber(digits: 1...2),
            let dot1 = token(index + 1), dot1.isSymbol("."), !dot1.spaced,
            let month = token(index + 2), month.isNumber(digits: 1...2),
            let dot2 = token(index + 3), dot2.isSymbol("."), !dot2.spaced,
            let year = token(index + 4), year.isNumber(digits: 2...4), year.text.count != 3
        else { return nil }
        let (full, strong) = fullYear(year)
        return (index + 4, Int(day.text) ?? 0, Int(month.text) ?? 0, full, strong, true)
    }

    /// `13/11/2026` (day first) or `11/13/2026` (month first), only when the order is clear.
    private func slashed(_ index: Int) -> (last: Int, day: Int, month: Int, year: Int, strong: Bool, valid: Bool)? {
        guard let first = token(index), first.isNumber(digits: 1...2),
            let slash1 = token(index + 1), slash1.isSymbol("/"), !slash1.spaced,
            let second = token(index + 2), second.isNumber(digits: 1...2), !second.spaced,
            let slash2 = token(index + 3), slash2.isSymbol("/"), !slash2.spaced,
            let year = token(index + 4), year.isNumber(digits: 2...4), year.text.count != 3, !year.spaced
        else { return nil }
        let a = Int(first.text) ?? 0
        let b = Int(second.text) ?? 0
        let (full, strong) = fullYear(year)
        if a == b || (a > 12 && b <= 12) { return (index + 4, a, b, full, strong, true) }
        if b > 12 && a <= 12 { return (index + 4, b, a, full, strong, true) }
        return (index + 4, 0, 0, full, strong, false)
    }

    /// `13. November 2026`, `13 Nov. 2026`, `13.Nov.2026`, `13th (of) November 2026`, `13-Nov-2026`.
    private func dayMonthName(_ index: Int) -> (last: Int, day: Int, month: Int, year: Int, strong: Bool, valid: Bool)?
    {
        guard let day = token(index), day.isNumber(digits: 1...2) else { return nil }
        var next = index + 1
        if let ordinal = token(next), ordinal.kind == .word, !ordinal.spaced,
            ["st", "nd", "rd", "th"].contains(ordinal.text)
        {
            next += 1
        }
        if let separator = token(next), separator.isSymbol(".") || separator.isSymbol("-"), !separator.spaced {
            next += 1
        }
        if let of = token(next), of.kind == .word, of.text == "of", of.spaced { next += 1 }
        guard let name = token(next), name.kind == .word, let month = MonthNames.month(named: name.text) else {
            return nil
        }
        next += 1
        if let dot = token(next), dot.isSymbol("."), !dot.spaced { next += 1 }
        if let separator = token(next), separator.isSymbol("-") || separator.isSymbol(","), !separator.spaced {
            next += 1
        }
        guard let year = token(next), year.isNumber(digits: 4...4) else { return nil }
        return (next, Int(day.text) ?? 0, month, Int(year.text) ?? 0, true, true)
    }

    /// `November 13, 2026`, `Nov. 13 2026`, `November 13th, 2026`.
    private func monthNameDay(_ index: Int) -> (last: Int, day: Int, month: Int, year: Int, strong: Bool, valid: Bool)?
    {
        guard let name = token(index), name.kind == .word, let month = MonthNames.month(named: name.text) else {
            return nil
        }
        var next = index + 1
        if let dot = token(next), dot.isSymbol("."), !dot.spaced { next += 1 }
        guard let day = token(next), day.isNumber(digits: 1...2), day.spaced else { return nil }
        next += 1
        if let ordinal = token(next), ordinal.kind == .word, !ordinal.spaced,
            ["st", "nd", "rd", "th"].contains(ordinal.text)
        {
            next += 1
        }
        if let comma = token(next), comma.isSymbol(","), !comma.spaced { next += 1 }
        guard let year = token(next), year.isNumber(digits: 4...4), year.spaced else { return nil }
        return (next, Int(day.text) ?? 0, month, Int(year.text) ?? 0, true, true)
    }

    /// `01.10.` of a range `01.10.–31.10.2026`: a day and a month with no year after them.
    private func dayMonthOnly(_ index: Int) -> Int? {
        guard let day = token(index), day.isNumber(digits: 1...2),
            let dot1 = token(index + 1), dot1.isSymbol("."), !dot1.spaced,
            let month = token(index + 2), month.isNumber(digits: 1...2), !month.spaced,
            let dot2 = token(index + 3), dot2.isSymbol("."), !dot2.spaced
        else { return nil }
        if let next = token(index + 4), next.kind == .number { return nil }
        return index + 3
    }

    private func fullYear(_ token: Token) -> (year: Int, fourDigits: Bool) {
        let value = Int(token.text) ?? 0
        return token.text.count == 4 ? (value, true) : (window.fullYear(twoDigit: value), false)
    }

    static func isValid(day: Int, month: Int, year: Int) -> Bool {
        guard (1...12).contains(month), day >= 1 else { return false }
        let leap = (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
        let days = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
        return day <= days[month - 1]
    }
}
