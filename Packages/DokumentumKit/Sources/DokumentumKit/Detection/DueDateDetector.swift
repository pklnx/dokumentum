import Foundation

/// What a due date in a letter is for (#12, part 2b; plan §5): the kind of the cue that names it. The app shows it in
/// the suggestion and stores its localized name as the deadline's label when the user adds it.
public enum DueDateKind: String, CaseIterable, Hashable, Sendable {
    /// `zahlbar bis`, `fällig am`, `Zahlungsziel`, `due`, `payable by` …
    case payment
    /// `Kündigung bis`, `kündbar zum`, `cancel by`.
    case cancellation
    /// `gültig bis`, `Ablauf`, `expires`, `valid until` …
    case expiry
    /// `Frist`, `…frist`, `spätestens`, `deadline`, `no later than` …, and a bare `bis`.
    case deadline
}

/// One day a letter's text names as due, with the kind of its cue.
public struct DueDateCandidate: Hashable, Sendable {
    public var day: DeadlineDay
    public var kind: DueDateKind

    public init(day: DeadlineDay, kind: DueDateKind) {
        self.day = day
        self.kind = kind
    }
}

/// The due dates in a document's text (#12, part 2b; plan §5): text only, deterministic, never written anywhere. The
/// detail offers the earliest one as a suggestion (`suggestion(among:today:dismissedThrough:)`), and only the user's
/// "Add Deadline" sets it (maintainer decision Q2): nothing automatic writes a deadline.
///
/// **Input:** the first `DetectionLimits.dueDatePages` (5) pages with text (the stored text split at form feeds), and
/// the document's `createdAt`. Lines are folded and compound labels joined as `IssueDateDetector` does it, and the
/// date forms are `IssueDateDetector`'s (`DateScanner`): numeric with dots, month names in German and English, ISO, and
/// slashes only when unambiguous; never inside a longer number or code (`RE-2026-11-27-001`, an IBAN).
///
/// **Which dates count:**
/// - a date with a cue (`germanCues`, `englishCues`, a word ending in `germanSuffixCues`, all for every document)
///   between the previous date of its line (or the line's start) and itself;
/// - a date that stands alone at the end of its line (no word before it there: not `Rechnungsdatum 27.11.2026`, not a
///   place line `Hamburg, 27.11.2026`) when the previous line ends with a cue (optionally followed by `:` and one
///   preposition: `Fällig am` / `27.11.2026`, `Zahlbar bis zum` / `27.11.2026`), unless the previous line ends with a
///   date and a range connector (a range split over two lines);
/// - a bare `bis` / `bis zum` / `bis zur` counts as `deadline` only directly before the date and when no other cue is
///   there (`Betrag bis 27.11.2026`; not `Montag bis Freitag, … 20.11.2026`, not `bis auf Weiteres … 01.01.2027`; fix
///   round 1 of #220, N2).
///
/// **A date its own label names as something else is never due**, whatever cue stands earlier on its line (fix round 1
/// of #220, N1): the text right before it ends with an issue-date label (`IssueDateDetector.labels`: `Rechnungsdatum`,
/// `ausgestellt am`, `Invoice date`) or with an issue-date cue that is no due cue (`Vertragsbeginn:`, `geboren am`,
/// `Termin am`). So `Zahlbar bis 14 Tage nach Rechnungsdatum 14.11.2026` gives nothing. `Due to` is no cue (N3).
///
/// Never either date of a range (`01.10.2026 – 31.10.2026`, `01.10.–31.10.2026`, `vom 01.01. bis 31.12.2026`: a pinned
/// miss for validity periods), and never a date without a cue (`Rechnungsdatum`, `Datum`, a birth date).
///
/// **The kind:** with several cues before a date, a specific one (payment, cancellation, expiry) wins over the general
/// `deadline`, and among specific ones the cue closest to the date: `Zahlbar bis spätestens` is a payment,
/// `Kündigungsfrist: Kündigung bis zum` a cancellation.
///
/// **Window:** from `createdAt` − 60 days to `createdAt` + 1,095 days (`DetectionLimits.dueWindowBefore`,
/// `dueWindowAfter`), as calendar days in `calendar` (UTC by default, as `IssueDateDetector`). **A two-digit year** is
/// `20yy` unless that is after the window's last year, then `19yy` (review N4 of #12's plan): `31.12.28` in a 2026
/// letter is 2028, where the issue date's pivot (`createdAt`'s year + 1) would read 1928.
///
/// **Result:** one candidate per day (the first in reading order gives its kind), in day order.
///
/// **Out of scope** (plan §5; known limits of the detectors are collected in #206): relative deadlines ("innerhalb von
/// 14 Tagen") and appointments (`Termin`).
public enum DueDateDetector {
    /// German cues by kind (folded before matching; whole words).
    public static let germanCues: [DueDateKind: [String]] = [
        .payment: [
            "zahlbar bis", "zahlbar am", "zahlbar spätestens", "fällig am", "fällig bis", "fällig zum", "Fälligkeit",
            "Fälligkeitsdatum", "Zahlungsziel",
        ],
        .cancellation: ["Kündigung bis", "Kündigung zum", "kündbar bis", "kündbar zum"],
        .expiry: ["gültig bis", "Ablauf", "Ablaufdatum"],
        .deadline: [
            "Frist", "spätestens", "bis spätestens", "Abgabe bis", "einzureichen bis", "Rückmeldung bis",
        ],
    ]
    /// English cues by kind.
    public static let englishCues: [DueDateKind: [String]] = [
        .payment: ["due", "due date", "due by", "payment due", "payable by", "pay by"],
        .cancellation: ["cancel by"],
        .expiry: ["expires", "expiry date", "expiration date", "valid until"],
        .deadline: ["deadline", "respond by", "reply by", "no later than"],
    ]
    /// German compound cues, matched as the end of a word: `Einspruchsfrist`, `Zahlungsfrist` (kind `deadline`).
    public static let germanSuffixCues = ["frist"]
    /// A bare `bis` names a deadline only when no other cue is before the date.
    public static let bareCues = ["bis", "bis zum", "bis zur"]
    /// Phrases that hold a cue but name no due date: `Due to maintenance, …` (fix round 1 of #220, N3).
    public static let notCues = ["due to"]

    /// One folded cue.
    struct Cue {
        let text: String
        let kind: DueDateKind
    }

    static let cues: [Cue] = DueDateKind.allCases.flatMap { kind in
        ((germanCues[kind] ?? []) + (englishCues[kind] ?? [])).map { Cue(text: SuggestionRules.fold($0), kind: kind) }
    }
    static let foldedBareCues = bareCues.map(SuggestionRules.fold)
    static let foldedNotCues = notCues.map(SuggestionRules.fold)

    /// The due dates in a document's text: its first five pages with text are read.
    public static func candidates(
        in text: String, createdAt: Date, calendar: Calendar = IssueDateDetector.utcCalendar
    ) -> [DueDateCandidate] {
        let pages = text.split(separator: "\u{0C}", omittingEmptySubsequences: false)
            .filter { !$0.allSatisfy(\.isWhitespace) }
            .prefix(DetectionLimits.dueDatePages)
        let window = window(createdAt: createdAt, calendar: calendar)
        var found: [DueDateCandidate] = []
        for page in pages {
            found += candidates(lines: page.split(whereSeparator: \.isNewline).map(String.init), window: window)
        }
        var days = Set<DeadlineDay>()
        return found.filter { days.insert($0.day).inserted }.sorted { $0.day < $1.day }
    }

    /// The suggestion among `candidates` (plan §5, review B3): the earliest that is today or later and **after** the
    /// day suggestions are dismissed up to. So dismissing it offers the next later one, and dismissing that leaves
    /// none; a later day (a new scan) is offered again, an earlier one never.
    public static func suggestion(
        among candidates: [DueDateCandidate], today: DeadlineDay, dismissedThrough dismissed: DeadlineDay?
    ) -> DueDateCandidate? {
        candidates.filter { candidate in
            candidate.day >= today && dismissed.map { candidate.day > $0 } ?? true
        }
        .min { $0.day < $1.day }
    }

    /// Whether the detail offers `candidate` for `document` on `today` (maintainer decision Q2): only while the document
    /// has no deadline (open or done), is processed (`done`), is not in the trash, and the day is still ahead of the
    /// dismissed day and not past. Accepting it then never cuts into the issue date's processing (#8).
    public static func offers(_ candidate: DueDateCandidate, for document: LibraryDocument, today: DeadlineDay) -> Bool
    {
        guard document.deadline == nil, document.processingState == .done, !document.isTrashed else { return false }
        return suggestion(among: [candidate], today: today, dismissedThrough: document.dismissedSuggestionDay) != nil
    }

    // MARK: Reading

    /// The window for a document created at `createdAt`; the two-digit years pivot on its last year (N4).
    static func window(createdAt: Date, calendar: Calendar) -> Window {
        let latest = Window.day(DetectionLimits.dueWindowAfter, after: createdAt, calendar: calendar)
        return Window(
            earliest: Window.day(-DetectionLimits.dueWindowBefore, after: createdAt, calendar: calendar),
            latest: latest, pivotYear: latest.year)
    }

    /// The due dates in one page's lines, in reading order.
    static func candidates(lines: [String], window: Window) -> [DueDateCandidate] {
        let folded = lines.map { IssueDateDetector.joiningCompoundLabels(SuggestionRules.fold($0)) }
            .filter { !$0.isEmpty }
        var result: [DueDateCandidate] = []
        var previousCue: DueDateKind?
        for line in folded {
            let characters = Array(line)
            let found = DateScanner(tokens: Token.split(characters), window: window).scan()
            for (position, item) in found.enumerated() where item.isComplete {
                if IssueDateDetector.isRange(found, at: position, in: characters) { continue }
                let segmentStart = position > 0 ? found[position - 1].end : 0
                let segment = masked(String(characters[segmentStart..<item.start]))
                if isLabelledAsAnotherDate(segment) { continue }
                let after = String(characters[item.end...]).trimmingCharacters(in: .whitespaces)
                let endsLine = after.isEmpty || after == "."
                var kind = kind(in: segment)
                if kind == nil, endsLine, !segment.contains(where: \.isLetter) {
                    kind = previousCue
                }
                guard let kind, let date = item.date, window.contains(date), let day = DeadlineDay(date) else {
                    continue
                }
                result.append(DueDateCandidate(day: day, kind: kind))
            }
            let trailing = String(characters[(found.last?.end ?? 0)...])
            let trailingIsConnector =
                !found.isEmpty
                && IssueDateDetector.rangeConnectors.contains(trailing.trimmingCharacters(in: .whitespaces))
            previousCue = trailingIsConnector ? nil : kind(atEndOf: masked(trailing))
        }
        return result
    }

    /// The kind the cues in `segment` (folded) give a date right after it: a specific kind before `deadline`, then the
    /// cue closest to the date; a bare `bis` only without any other cue, and only right before the date (N2).
    static func kind(in segment: String) -> DueDateKind? {
        var closest: (end: Int, kind: DueDateKind)?
        var general = false
        for cue in cues {
            guard let end = lastBoundedEnd(of: cue.text, in: segment) else { continue }
            if cue.kind == .deadline {
                general = true
            } else if closest.map({ end > $0.end }) ?? true {
                closest = (end, cue.kind)
            }
        }
        if let closest { return closest.kind }
        if general || germanSuffixCues.contains(where: { IssueDateDetector.endsAWord($0, in: segment) }) {
            return .deadline
        }
        let end = Substring(segment).trimmingSuffix(\.isWhitespace)
        return foldedBareCues.contains { IssueDateDetector.endsWithWord(end, $0) } ? .deadline : nil
    }

    /// Whether the text right before a date (folded) labels it as another date (N1): it ends with an issue-date label,
    /// or with an issue-date cue (optionally `:` and one preposition) that is no due cue.
    static func isLabelledAsAnotherDate(_ segment: String) -> Bool {
        IssueDateDetector.endsWithLabel(segment, strict: true)
            || (IssueDateDetector.endsWithCue(segment) && kind(atEndOf: segment) == nil)
    }

    /// `folded` with every phrase of `notCues` blanked out (the same length, so cue positions stay).
    static func masked(_ folded: String) -> String {
        var result = folded
        for phrase in foldedNotCues {
            while let end = lastBoundedEnd(of: phrase, in: result) {
                let upper = result.index(result.startIndex, offsetBy: end)
                let lower = result.index(upper, offsetBy: -phrase.count)
                result.replaceSubrange(lower..<upper, with: String(repeating: " ", count: phrase.count))
            }
        }
        return result
    }

    /// The kind of a cue that ends `folded` (a line's text after its last date), optionally followed by `:` and one
    /// preposition (`Fällig am`, `Zahlbar bis zum:`); a specific kind before `deadline` and the bare `bis`.
    static func kind(atEndOf folded: String) -> DueDateKind? {
        var text = Substring(folded).trimmingSuffix(\.isWhitespace)
        if text.last == ":" { text = text.dropLast().trimmingSuffix(\.isWhitespace) }
        var endings = [text]
        if let last = text.split(separator: " ").last, IssueDateDetector.cuePrepositions.contains(String(last)) {
            var stripped = text.dropLast(last.count).trimmingSuffix(\.isWhitespace)
            if stripped.last == ":" { stripped = stripped.dropLast().trimmingSuffix(\.isWhitespace) }
            endings.append(stripped)
        }
        for ending in endings {
            if let cue = cues.first(where: { $0.kind != .deadline && IssueDateDetector.endsWithWord(ending, $0.text) })
            {
                return cue.kind
            }
        }
        for ending in endings {
            if cues.contains(where: { $0.kind == .deadline && IssueDateDetector.endsWithWord(ending, $0.text) }) {
                return .deadline
            }
            if let last = ending.split(separator: " ").last,
                germanSuffixCues.contains(where: { String(last).hasSuffix($0) })
            {
                return .deadline
            }
            if foldedBareCues.contains(where: { IssueDateDetector.endsWithWord(ending, $0) }) { return .deadline }
        }
        return nil
    }

    /// The character offset where the last occurrence of `needle` in `haystack` ends, with no letter or digit right
    /// before or after it; `nil` when there is none.
    static func lastBoundedEnd(of needle: String, in haystack: String) -> Int? {
        func isWordCharacter(_ character: Character?) -> Bool {
            guard let character else { return false }
            return character.isLetter || character.isNumber
        }
        var searchStart = haystack.startIndex
        var end: Int?
        while let range = haystack.range(of: needle, range: searchStart..<haystack.endIndex) {
            let before =
                range.lowerBound > haystack.startIndex ? haystack[haystack.index(before: range.lowerBound)] : nil
            let after = range.upperBound < haystack.endIndex ? haystack[range.upperBound] : nil
            if !isWordCharacter(before), !isWordCharacter(after) {
                end = haystack.distance(from: haystack.startIndex, to: range.upperBound)
            }
            searchStart = haystack.index(after: range.lowerBound)
        }
        return end
    }
}
