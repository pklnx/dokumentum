import Foundation

/// The sender a letter's layout names: a live correspondent, or a name read from the letter's structure.
public enum DetectedSender: Equatable, Sendable {
    /// A known correspondent (`MetadataMatcher.Record.id`) whose name occurs in a sender zone.
    case existing(id: UUID, name: String)
    /// A name from the structure: the return-address line's first segment, or a company name with a legal form.
    /// The write resolves it against the live correspondents (`MetadataMatcher.match`), else creates one.
    case name(String)
}

/// The sender of a letter, from the layout of its first page with text and the live correspondents (plan of #11,
/// Approach 3; review B1, B2; re-review R1-B1, N-r2, N-r3, N-r4).
///
/// Geometry is in DIN 5008 millimetres (`DetectionLimits`, `PageGeometry`). Lines are classified first:
/// - **Return-address line**: the topmost line whose left edge lies in the field's x-range (10–110 mm) at or below a
///   form's field top (with the zone's tolerance), with its top in that form's return-address zone; at least two
///   field lines below it, down to the form's bottom; its height at most 0.8 × their median height (required); at
///   least two segments, a later one with a postcode. Form B is tried before form A: a form B letterhead may reach
///   into form A's zone.
/// - **Recipient lines**: the field lines below the return-address line, down to the form's bottom; without one,
///   every line of the union area (x 10–110 mm, y 27–90 mm). So a form B letterhead without a return-address line
///   counts as recipient lines: a pinned miss (N-r3).
/// - **Recipient-labelled lines**: every line holding a `recipientLabels` entry; a line that is only a label covers
///   its column block below it (lines overlapping it horizontally, down to the first gap of more than 1.5 line
///   heights, N-r2).
/// - **Letterhead**: lines above the field top (27 mm, or 45 mm with a form B return-address line) and the
///   info-block column (from x 125 mm, down to 100 mm), without recipient and recipient-labelled lines.
/// - **Footer**: lines in the page's last 47 mm, grouped into column blocks (overlapping horizontally, gaps below
///   1.5 line heights); a block with a `footerCues` line is dropped as a whole (B2).
///
/// **Recipient exclusion** (B1.1): a known correspondent whose name occurs in a recipient or recipient-labelled line
/// is never detected; a structural name equal to or contained in such a line is rejected.
///
/// The zones are tried in the order return-address line, letterhead, footer; the first with a result wins:
/// 1. a known correspondent whose name occurs in the zone (folded, whole words); a name inside another found name
///    yields to the longer; two distinct names give **none for the document**;
/// 2. else a structural name: the return-address line's first segment, unless it is a street, a post box or holds
///    a postcode; in the letterhead (topmost first) and the footer, a segment with a legal form, cut after it, with
///    a leading `©` and years dropped. It must be 2–80 characters, at most 8 words, with a letter, and no
///    placeholder.
public enum SenderDetector {
    public static let recipientLabels = [
        "Kunde", "Kundin", "Versicherungsnehmer", "Patient", "Mandant", "Empfänger", "Anschrift", "Lieferadresse",
        "Rechnungsadresse", "Rechnungsanschrift", "Lieferanschrift", "Rechnung an", "Lieferung an", "Bill to",
        "Bill-to", "Ship to", "Ship-to", "Sold to", "Deliver to", "Invoice to", "Customer", "Account holder",
        "Policyholder",
    ]
    /// A footer column block with one of these is bank or register data, never a sender (B2).
    public static let footerCues = [
        "IBAN", "BIC", "SWIFT", "Bankverbindung", "Bank", "Konto", "Sort code", "Account", "Amtsgericht",
        "Registergericht", "Handelsregister", "HRB", "HRA", "PR", "VR", "Sitz", "USt-IdNr", "Steuernummer",
        "Geschäftsführer", "Vorstand", "Aufsichtsrat", "Company number", "Registered office", "VAT", "Directors",
    ]
    /// Legal forms, as words; a word's trailing `.`, `,`, `;` or `:` is ignored when comparing.
    public static let legalForms = [
        "GmbH & Co. KG", "UG (haftungsbeschränkt)", "PartG mbB", "GmbH", "gGmbH", "mbH", "AG", "KG", "KGaA", "OHG",
        "GbR", "e.V.", "eG", "e.K.", "SE", "PartG", "mbB", "Ltd", "Limited", "LLC", "Inc.", "Corp.", "PLC", "LLP",
    ]

    static let foldedRecipientLabels = recipientLabels.map(SuggestionRules.fold)
    static let foldedFooterCues = footerCues.map(SuggestionRules.fold)
    static let legalFormWords: [[String]] = legalForms.map { form in
        form.split(separator: " ").map { comparable(String($0)) }
    }

    /// The sender of the page, or `nil` (nothing found, or ambiguous).
    public static func detect(in layout: PageLayout, known: [MetadataMatcher.Record]) -> DetectedSender? {
        let page = Page(layout)
        let lines = page.lines
        guard !lines.isEmpty else { return nil }

        // Recipient lines and recipient-labelled lines.
        let returnLine = page.returnAddressLine()
        let fieldTop = returnLine?.form.top ?? DetectionLimits.formA.top
        var recipient = Set<Int>()
        if let returnLine {
            let line = lines[returnLine.index]
            for other in lines
            where page.isFieldLine(other) && other.box.midY > line.box.maxY
                && other.box.midY <= returnLine.form.bottom
            {
                recipient.insert(other.index)
            }
        } else {
            for line in lines where page.isFieldLine(line) && DetectionLimits.recipientArea.contains(line.box.midY) {
                recipient.insert(line.index)
            }
        }
        let labelled = page.labelledLines()
        let recipientText = (recipient.union(labelled)).sorted().map { lines[$0].folded }

        let names = known.map { (record: $0, folded: SuggestionRules.fold($0.name)) }.filter { !$0.folded.isEmpty }
        let candidates = names.filter { name in
            !recipientText.contains { Folded.containsBounded(name.folded, in: $0) }
        }

        // The zones.
        var zones: [Zone] = []
        if let returnLine { zones.append(Zone(kind: .returnAddress, lines: [lines[returnLine.index]])) }
        let letterhead = lines.filter { line in
            line.index != returnLine?.index && !recipient.contains(line.index) && !labelled.contains(line.index)
                && (line.box.midY < fieldTop
                    || (line.box.minX >= DetectionLimits.infoBlockLeft
                        && line.box.midY <= DetectionLimits.infoBlockBottom))
        }
        zones.append(Zone(kind: .letterhead, lines: letterhead.sorted { $0.box.minY < $1.box.minY }))
        zones.append(Zone(kind: .footer, lines: page.footerLines()))

        for zone in zones {
            let text = zone.lines.map(\.folded).joined(separator: "\n")
            var found = candidates.filter { Folded.containsBounded($0.folded, in: text) }
            found = found.filter { name in
                !found.contains { $0.folded != name.folded && Folded.containsBounded(name.folded, in: $0.folded) }
            }
            if let first = found.first {
                guard found.allSatisfy({ $0.folded == first.folded }) else { return nil }
                return .existing(id: first.record.id, name: first.record.name)
            }
            for name in zone.structuralNames() where isAcceptable(name, recipientText: recipientText) {
                return .name(name)
            }
        }
        return nil
    }

    // MARK: Names

    /// A structural name passes the classifier's name checks and is in no recipient line.
    static func isAcceptable(_ name: String, recipientText: [String]) -> Bool {
        guard DetectionLimits.nameCharacters.contains(name.count),
            name.split(whereSeparator: \.isWhitespace).count <= DetectionLimits.nameWords,
            name.contains(where: \.isLetter), !SuggestionRules.isPlaceholder(name),
            !isStreet(name), !isPostBox(name), !hasPostcode(name)
        else { return false }
        let folded = SuggestionRules.fold(name)
        return !recipientText.contains { Folded.containsBounded(folded, in: $0) }
    }

    /// A line split into segments: at `·`, `•`, `|` when it has one; otherwise at commas, ` – ` and ` - ` (N4).
    static func segments(_ text: String) -> [String] {
        let strong: [String] = ["·", "•", "|"].filter { text.contains($0) }
        var parts = [text]
        for separator in strong.isEmpty ? [",", " – ", " - "] : strong {
            parts = parts.flatMap { $0.components(separatedBy: separator) }
        }
        return parts.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// The company name in a segment: the words up to the last legal form, with a leading `©` and years dropped.
    /// A segment that is only a legal form joins the segment before it (`Fabrikam, Inc.`).
    static func legalFormNames(in text: String) -> [String] {
        let parts = segments(text)
        var names: [String] = []
        for (index, part) in parts.enumerated() {
            guard var company = companyWords(part) else { continue }
            if company.formStart == 0, index > 0 {
                var head = parts[index - 1].split(whereSeparator: \.isWhitespace).map(String.init)
                head[head.count - 1] += ","
                company = (head + company.words, head.count)
            }
            let dropped = company.words.prefix(while: isYearOrCopyright).count
            guard dropped < company.formStart else { continue }
            names.append(company.words.dropFirst(dropped).joined(separator: " "))
        }
        return names
    }

    /// The words of `segment` up to and with its last legal form (that word's trailing `,`, `;`, `:` dropped, and its
    /// `.` unless the form ends with one) and where that form starts, or `nil` without a legal form.
    static func companyWords(_ segment: String) -> (words: [String], formStart: Int)? {
        let words = segment.split(whereSeparator: \.isWhitespace).map(String.init)
        let keys = words.map(comparable)
        var best: (start: Int, end: Int, form: String)?
        for (form, formKeys) in zip(legalForms, legalFormWords) where formKeys.count <= keys.count {
            for start in 0...(keys.count - formKeys.count)
            where Array(keys[start..<(start + formKeys.count)]) == formKeys {
                let end = start + formKeys.count - 1
                if let current = best, end < current.end || (end == current.end && start >= current.start) {
                    continue
                }
                best = (start, end, form)
            }
        }
        guard let best else { return nil }
        var result = Array(words[0...best.end])
        var last = result[best.end]
        while let character = last.last, [",", ";", ":"].contains(character) { last.removeLast() }
        if !best.form.hasSuffix("."), last.hasSuffix(".") { last.removeLast() }
        result[best.end] = last
        return (result, best.start)
    }

    static func isYearOrCopyright(_ word: String) -> Bool {
        if ["©", "(c)"].contains(word.lowercased()) { return true }
        let trimmed = word.trimmingCharacters(in: CharacterSet(charactersIn: "©,"))
        guard !trimmed.isEmpty else { return true }
        let years = trimmed.split { $0 == "-" || $0 == "–" }
        return !years.isEmpty && years.allSatisfy { $0.count == 4 && $0.allSatisfy { $0.isASCII && $0.isNumber } }
    }

    /// A word as legal forms are compared: folded, trailing `.`, `,`, `;`, `:` dropped.
    static func comparable(_ word: String) -> String {
        var key = SuggestionRules.fold(word)
        while let last = key.last, [".", ",", ";", ":"].contains(last) { key.removeLast() }
        return key
    }

    // MARK: Addresses

    /// A street: a house number at its end (`Musterweg 2`, `Hauptstr. 5a`), a number first (`45 Oak Avenue`), or a
    /// street word (`…straße`, `…weg`, `Street`, `Road`, …).
    static func isStreet(_ segment: String) -> Bool {
        let words = segment.split(whereSeparator: \.isWhitespace).map(String.init)
        guard let last = words.last, let first = words.first else { return false }
        if words.count >= 2 {
            let number = last.trimmingCharacters(in: CharacterSet(charactersIn: ".,"))
            let digits = number.prefix { $0.isASCII && $0.isNumber }
            let rest = number.dropFirst(digits.count)
            if !digits.isEmpty, rest.count <= 1 || rest.first == "-" { return true }
            if first.allSatisfy({ $0.isASCII && $0.isNumber }) { return true }
        }
        let folded = SuggestionRules.fold(segment)
        let germanSuffixes = ["strasse", "str.", "weg", "platz", "allee", "gasse", "damm", "ufer"]
        if folded.split(separator: " ").contains(where: { word in germanSuffixes.contains { word.hasSuffix($0) } }) {
            return true
        }
        let englishWords = ["street", "road", "avenue", "lane", "drive", "boulevard"]
        return englishWords.contains { Folded.containsBounded($0, in: folded) }
    }

    static func isPostBox(_ segment: String) -> Bool {
        let folded = SuggestionRules.fold(segment)
        return ["postfach", "po box", "p.o. box", "p. o. box", "postbox"].contains { folded.hasPrefix($0) }
    }

    /// A postcode: 4–5 digits before a word (`80331 München`), a UK postcode (`M1 1AE`), or a US state and ZIP
    /// (`OR 97201`).
    static func hasPostcode(_ segment: String) -> Bool {
        let words = segment.split(whereSeparator: \.isWhitespace).map(String.init)
        for (index, word) in words.enumerated() {
            let next = index + 1 < words.count ? words[index + 1] : nil
            if (4...5).contains(word.count), word.allSatisfy({ $0.isASCII && $0.isNumber }),
                let next, next.first?.isLetter == true
            {
                return true
            }
            if let next, isUKOutward(word), isUKInward(next.trimmingCharacters(in: CharacterSet(charactersIn: ".,"))) {
                return true
            }
            if let next, word.count == 2, word.allSatisfy({ $0.isASCII && $0.isUppercase }), isZIP(next) {
                return true
            }
        }
        return false
    }

    /// `M1`, `SW1A`, `EC2V`: one or two letters, a digit, an optional letter or digit.
    static func isUKOutward(_ word: String) -> Bool {
        let characters = Array(word)
        guard (2...4).contains(characters.count), characters.allSatisfy({ $0.isASCII }) else { return false }
        let letters = characters.prefix { $0.isUppercase }
        guard (1...2).contains(letters.count) else { return false }
        let rest = characters.dropFirst(letters.count)
        guard let digit = rest.first, digit.isNumber else { return false }
        guard let last = rest.last, rest.count <= 2 else { return false }
        return rest.count == 1 || last.isNumber || last.isUppercase
    }

    /// `1AE`: a digit and two letters.
    static func isUKInward(_ word: String) -> Bool {
        let characters = Array(word)
        return characters.count == 3 && characters.allSatisfy(\.isASCII) && characters[0].isNumber
            && characters[1].isUppercase && characters[2].isUppercase
    }

    /// `97201` or `97201-1234`.
    static func isZIP(_ word: String) -> Bool {
        let trimmed = word.trimmingCharacters(in: CharacterSet(charactersIn: ".,"))
        let parts = trimmed.split(separator: "-", omittingEmptySubsequences: false)
        guard parts[0].count == 5, parts[0].allSatisfy({ $0.isASCII && $0.isNumber }) else { return false }
        return parts.count == 1 || (parts.count == 2 && parts[1].count == 4 && parts[1].allSatisfy(\.isNumber))
    }
}

/// One line in millimetres, folded once.
struct PageLine {
    let index: Int
    let text: String
    let folded: String
    let box: MillimetreBox
}

/// A sender zone and the structural names it offers.
struct Zone {
    enum Kind { case returnAddress, letterhead, footer }

    let kind: Kind
    let lines: [PageLine]

    func structuralNames() -> [String] {
        switch kind {
        case .returnAddress:
            guard let first = lines.first.flatMap({ SenderDetector.segments($0.text).first }) else { return [] }
            return [first]
        case .letterhead, .footer:
            return lines.flatMap { SenderDetector.legalFormNames(in: $0.text) }
        }
    }
}

/// The page's lines in millimetres and what the zones need of them.
struct Page {
    let geometry: PageGeometry
    let lines: [PageLine]

    init(_ layout: PageLayout) {
        geometry = layout.geometry
        var lines: [PageLine] = []
        for line in layout.lines {
            let text = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            lines.append(
                PageLine(
                    index: lines.count, text: text, folded: SuggestionRules.fold(text),
                    box: geometry.millimetres(line.box)))
        }
        self.lines = lines
    }

    func isFieldLine(_ line: PageLine) -> Bool {
        DetectionLimits.acceptedFieldX.contains(line.box.minX)
    }

    /// The return-address line and its form (form B first), or `nil`.
    func returnAddressLine() -> (index: Int, form: DetectionLimits.AddressForm)? {
        let field = lines.filter(isFieldLine)
        for form in [DetectionLimits.formB, DetectionLimits.formA] {
            let zone = form.returnZone
            let topmost = field.filter { $0.box.minY >= zone.lowerBound }.min { $0.box.minY < $1.box.minY }
            guard let candidate = topmost, zone.contains(candidate.box.minY) else { continue }
            let below = field.filter { $0.box.midY > candidate.box.maxY && $0.box.midY <= form.bottom }
            guard below.count >= DetectionLimits.returnLineMinimumLinesBelow else { continue }
            let heights = below.map(\.box.height).sorted()
            let middle = heights.count / 2
            let median = heights.count % 2 == 1 ? heights[middle] : (heights[middle - 1] + heights[middle]) / 2
            guard candidate.box.height <= DetectionLimits.returnLineHeightRatio * median else { continue }
            let parts = SenderDetector.segments(candidate.text)
            guard parts.count >= 2, parts.dropFirst().contains(where: SenderDetector.hasPostcode) else { continue }
            return (candidate.index, form)
        }
        return nil
    }

    /// The lines holding a recipient label, and the column blocks below lines that are only a label (N-r2).
    func labelledLines() -> Set<Int> {
        var result = Set<Int>()
        for line in lines {
            guard SenderDetector.foldedRecipientLabels.contains(where: { Folded.containsBounded($0, in: line.folded) })
            else { continue }
            result.insert(line.index)
            var label = line.folded
            if label.hasSuffix(":") { label.removeLast() }
            label = label.trimmingCharacters(in: .whitespaces)
            guard SenderDetector.foldedRecipientLabels.contains(label) else { continue }
            var previous = line.box
            let below = lines.filter { $0.box.minY >= line.box.maxY - 0.01 && $0.box.overlapsHorizontally(line.box) }
                .sorted { $0.box.minY < $1.box.minY }
            for next in below {
                let gap = next.box.minY - previous.maxY
                guard gap <= DetectionLimits.blockGapLineHeights * max(previous.height, next.box.height) else { break }
                result.insert(next.index)
                previous = next.box
            }
        }
        return result
    }

    /// The footer's lines without the column blocks that hold a bank or register cue (B2), top to bottom.
    func footerLines() -> [PageLine] {
        let footer = lines.filter { $0.box.midY > geometry.footerTop }
        var block = Array(0..<footer.count)
        func root(_ item: Int) -> Int {
            var item = item
            while block[item] != item { item = block[item] }
            return item
        }
        for a in footer.indices {
            for b in footer.indices where a < b && footer[a].box.overlapsHorizontally(footer[b].box) {
                let (upper, lower) = footer[a].box.minY <= footer[b].box.minY ? (a, b) : (b, a)
                let gap = footer[lower].box.minY - footer[upper].box.maxY
                let limit = DetectionLimits.blockGapLineHeights * max(footer[a].box.height, footer[b].box.height)
                if gap < limit { block[root(a)] = root(b) }
            }
        }
        var excluded = Set<Int>()
        for (index, line) in footer.enumerated()
        where SenderDetector.foldedFooterCues.contains(where: { Folded.containsBounded($0, in: line.folded) }) {
            excluded.insert(root(index))
        }
        return footer.indices.filter { !excluded.contains(root($0)) }.map { footer[$0] }
            .sorted { ($0.box.minY, $0.box.minX) < ($1.box.minY, $1.box.minX) }
    }
}
