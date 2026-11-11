import Foundation

/// A seeded, deterministic archive for the search's tests and benchmark (plan of #7, Approach 9): values only,
/// the benchmark (part 2) writes them into models. The same seed and count give the same corpus on every
/// platform: only integer arithmetic, no clock, no system random source.
///
/// - 60 correspondents, 12 document types, 40 tags on two levels (10 roots with 3 children each).
/// - Per document: a title, a correspondent (90 %), a type (85 %), 0–4 tags, a document date between 2015 and
///   2025, 10 % in the Inbox, 1 % trashed.
/// - Texts (P-f): 60 % one page, 30 % 2–5, 9 % 6–20, 1 % 30–100 pages of about 2,000 characters, pages joined
///   with a form feed; German and English words with umlauts and ß, compounds, line-end hyphenations, numbers,
///   dates and codes. Three documents have a text at the 500,000-byte cap of #6 (T7).
public struct SyntheticCorpus: Sendable {
    /// The cap of `DocumentText.extractedText` in UTF-8 bytes (#6, T7).
    public static let textCap = 500_000

    public struct Document: Sendable, Hashable {
        public let instanceID: UUID
        public let title: String
        public let correspondent: LibraryDocument.Reference?
        public let documentType: LibraryDocument.Reference?
        public let tagIDs: [UUID]
        public let documentDate: Date
        public let createdAt: Date
        public let isInbox: Bool
        public let deletedAt: Date?
        public let pageCount: Int
        /// The text fills the cap: at most `textCap` UTF-8 bytes and more than `textCap - 1_000`.
        public let fillsTextCap: Bool
        let textSeed: UInt64

        public var libraryDocument: LibraryDocument {
            LibraryDocument(
                instanceID: instanceID, title: title, documentDate: documentDate, createdAt: createdAt,
                isInbox: isInbox, deletedAt: deletedAt, correspondent: correspondent, documentType: documentType,
                tagIDs: Set(tagIDs), fileState: .present)
        }
    }

    public let seed: UInt64
    public let tags: [TagRecord]
    public let correspondents: [LibraryDocument.Reference]
    public let documentTypes: [LibraryDocument.Reference]
    public let documents: [Document]

    public init(count: Int, seed: UInt64 = 0x00D0_C0DE) {
        self.seed = seed
        var random = SplitMix64(seed: seed)

        var tags: [TagRecord] = []
        for (rootIndex, root) in Vocabulary.tagRoots.enumerated() {
            let rootID = random.uuid()
            tags.append(TagRecord(instanceID: rootID, parentInstanceID: nil, name: root))
            for child in 0..<3 {
                let name = Vocabulary.tagChildren[(rootIndex * 3 + child) % Vocabulary.tagChildren.count]
                tags.append(TagRecord(instanceID: random.uuid(), parentInstanceID: rootID, name: name))
            }
        }
        var correspondents: [LibraryDocument.Reference] = []
        for kind in Vocabulary.correspondentKinds {
            for city in Vocabulary.cities {
                correspondents.append(LibraryDocument.Reference(instanceID: random.uuid(), name: "\(kind) \(city)"))
            }
        }
        let documentTypes = Vocabulary.documentTypes.map {
            LibraryDocument.Reference(instanceID: random.uuid(), name: $0)
        }

        let capped: Set<Int> = count >= 3 ? [count / 4, count / 2, (3 * count) / 4] : []
        let start = Date(timeIntervalSinceReferenceDate: 441_763_200)  // 2015-01-01
        var documents: [Document] = []
        documents.reserveCapacity(count)
        for index in 0..<count {
            let instanceID = random.uuid()
            let type = random.below(100) < 85 ? documentTypes[random.below(documentTypes.count)] : nil
            let correspondent = random.below(100) < 90 ? correspondents[random.below(correspondents.count)] : nil
            var tagIDs: [UUID] = []
            for _ in 0..<random.below(5) {
                let id = tags[random.below(tags.count)].instanceID
                if !tagIDs.contains(id) { tagIDs.append(id) }
            }
            let day = random.below(4_000)
            let documentDate = start.addingTimeInterval(Double(day) * 86_400)
            let createdAt = documentDate.addingTimeInterval(Double(random.below(30 * 86_400)))
            let isInbox = random.below(100) < 10
            let deletedAt = random.below(100) < 1 ? createdAt.addingTimeInterval(86_400) : nil
            let pageClass = random.below(1_000)
            let pageCount: Int
            switch pageClass {
            case ..<600: pageCount = 1
            case ..<900: pageCount = 2 + random.below(4)
            case ..<990: pageCount = 6 + random.below(15)
            default: pageCount = 30 + random.below(71)
            }
            let title = [
                type?.name ?? "Dokument", Vocabulary.words[random.below(Vocabulary.words.count)],
                String(2015 + day / 365),
            ].joined(separator: " ")
            documents.append(
                Document(
                    instanceID: instanceID, title: title, correspondent: correspondent, documentType: type,
                    tagIDs: tagIDs, documentDate: documentDate, createdAt: createdAt, isInbox: isInbox,
                    deletedAt: deletedAt, pageCount: pageCount, fillsTextCap: capped.contains(index),
                    textSeed: random.next()))
        }
        self.tags = tags
        self.correspondents = correspondents
        self.documentTypes = documentTypes
        self.documents = documents
    }

    /// Every document, tag, correspondent and type as the library sees them.
    public var snapshot: LibrarySnapshot {
        LibrarySnapshot(
            documents: documents.map(\.libraryDocument), tags: tags, correspondents: correspondents,
            documentTypes: documentTypes)
    }

    /// The text of `document`, made on demand from its own seed (the corpus does not hold 37 MB of text).
    public func text(of document: Document) -> String {
        var random = SplitMix64(seed: document.textSeed)
        var text = ""
        if document.fillsTextCap {
            text.reserveCapacity(Self.textCap + 4_000)
            while text.utf8.count < Self.textCap {
                if !text.isEmpty { text += "\u{000C}" }
                Self.appendPage(to: &text, random: &random)
            }
            while text.utf8.count > Self.textCap { text.removeLast() }
            return text
        }
        for page in 0..<document.pageCount {
            if page > 0 { text += "\u{000C}" }
            Self.appendPage(to: &text, random: &random)
        }
        return text
    }

    /// FNV-1a over every value and text, in order: equal checksums mean equal corpora.
    public func checksum() -> UInt64 {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        func add(_ string: String) {
            for byte in string.utf8 {
                hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01B3
            }
            hash = (hash ^ 0xFF) &* 0x0000_0100_0000_01B3
        }
        for tag in tags { add("\(tag.instanceID) \(tag.parentInstanceID?.uuidString ?? "-") \(tag.name)") }
        for reference in correspondents + documentTypes { add("\(reference.instanceID) \(reference.name)") }
        for document in documents {
            add(
                [
                    document.instanceID.uuidString, document.title,
                    document.correspondent?.instanceID.uuidString ?? "-",
                    document.documentType?.instanceID.uuidString ?? "-",
                    document.tagIDs.map(\.uuidString).joined(separator: ","),
                    String(Int64(document.documentDate.timeIntervalSinceReferenceDate)),
                    String(Int64(document.createdAt.timeIntervalSinceReferenceDate)), String(document.isInbox),
                    String(document.deletedAt.map { Int64($0.timeIntervalSinceReferenceDate) } ?? -1),
                    String(document.pageCount),
                ].joined(separator: "|"))
            add(text(of: document))
        }
        return hash
    }

    // MARK: Text

    private static func appendPage(to text: inout String, random: inout SplitMix64) {
        let length = 1_800 + random.below(400)
        var written = 0
        var column = 0
        while written < length {
            let word = Self.word(&random)
            if column > 60, word.joinable, random.below(4) == 0 {
                // A compound broken at the line end, as OCR gives it: "Steuer-\nbescheid".
                let piece = word.head + "-\n" + word.tail
                text += piece
                written += piece.count
                column = word.tail.count
            } else {
                text += word.whole
                written += word.whole.count
                column += word.whole.count
            }
            if written >= length { break }
            if column > 70 {
                text += "\n"
                column = 0
            } else {
                text += " "
                column += 1
            }
            written += 1
        }
    }

    private struct Word {
        var whole: String
        var head = ""
        var tail = ""
        var joinable: Bool { !head.isEmpty }
    }

    private static func word(_ random: inout SplitMix64) -> Word {
        let kind = random.below(100)
        let words = Vocabulary.words
        switch kind {
        case ..<68:
            // Skewed towards the front of the list, as natural text is towards common words.
            let index = min(random.below(words.count), random.below(words.count), random.below(words.count))
            return Word(whole: words[index])
        case ..<83:
            let head = words[random.below(words.count)]
            let tail = words[random.below(words.count)].lowercased()
            return Word(whole: head + tail, head: head, tail: tail)
        case ..<92:
            return Word(whole: String(random.below(100_000)))
        case ..<95:
            let day = 1 + random.below(28)
            let month = 1 + random.below(12)
            let year = 2015 + random.below(11)
            return Word(whole: "\(day < 10 ? "0" : "")\(day).\(month < 10 ? "0" : "")\(month).\(year)")
        default:
            let letters = Array("ABCDEFGHJKLMNPQRSTUVWXYZ")
            let prefix = String((0..<3).map { _ in letters[random.below(letters.count)] })
            return Word(whole: "\(prefix)-\(random.below(1_000_000))")
        }
    }
}

/// SplitMix64: small, fast, and the same on every platform.
struct SplitMix64 {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }

    /// A value in `0..<bound`.
    mutating func below(_ bound: Int) -> Int {
        Int(next() % UInt64(bound))
    }

    /// A version 4 UUID from two draws.
    mutating func uuid() -> UUID {
        let high = next()
        let low = next()
        var bytes = [UInt8](repeating: 0, count: 16)
        for index in 0..<8 {
            bytes[index] = UInt8(truncatingIfNeeded: high >> (56 - 8 * UInt64(index)))
            bytes[8 + index] = UInt8(truncatingIfNeeded: low >> (56 - 8 * UInt64(index)))
        }
        bytes[6] = (bytes[6] & 0x0F) | 0x40
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(
            uuid: (
                bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7], bytes[8], bytes[9],
                bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
            ))
    }
}

private enum Vocabulary {
    static let tagRoots = [
        "Steuer", "Auto", "Wohnung", "Versicherung", "Gesundheit", "Bank", "Arbeit", "Familie", "Reisen", "Verträge",
    ]
    static let tagChildren = [
        "2023", "2024", "2025", "Golf", "Werkstatt", "Zulassung", "Miete", "Nebenkosten", "Handwerker", "Haftpflicht",
        "Hausrat", "Kfz", "Arzt", "Zahnarzt", "Apotheke", "Girokonto", "Kredit", "Depot", "Gehalt", "Zeugnis",
        "Rente", "Kinder", "Schule", "Kita", "Flüge", "Hotel", "Bahn", "Strom", "Telefon", "Fitness",
    ]
    static let correspondentKinds = [
        "Finanzamt", "Stadtwerke", "Sparkasse", "Volksbank", "Allianz", "Telekom", "Vodafone", "Praxis Dr. Müller",
        "Autohaus", "Hausverwaltung",
    ]
    static let cities = ["München", "Köln", "Hamburg", "Berlin", "Düsseldorf", "Nürnberg"]
    static let documentTypes = [
        "Rechnung", "Bescheid", "Vertrag", "Kontoauszug", "Mahnung", "Angebot", "Quittung", "Brief", "Police",
        "Lohnabrechnung", "Invoice", "Receipt",
    ]
    /// Common words first: the generator prefers the front of the list.
    static let words = [
        "der", "die", "das", "und", "für", "mit", "von", "auf", "bei", "ist", "nicht", "Sie", "wir", "Ihre", "the",
        "and", "for", "with", "you", "Rechnung", "Steuer", "Bescheid", "Finanzamt", "Versicherung", "Vertrag",
        "Kündigung", "Mieter", "Vermieter", "Wohnung", "Nebenkosten", "Abrechnung", "Strom", "Gas", "Wasser",
        "Krankenkasse", "Arzt", "Rezept", "Gehalt", "Lohn", "Bank", "Konto", "Überweisung", "Zahlung", "Betrag",
        "Euro", "Datum", "Frist", "Mahnung", "Auftrag", "Bestellung", "Lieferung", "Garantie", "Kaufvertrag",
        "Fahrzeug", "Kfz", "Zulassung", "Führerschein", "Ausweis", "Reisepass", "Schule", "Zeugnis", "Universität",
        "Prüfung", "Rente", "Behörde", "Gemeinde", "Stadt", "Straße", "Haus", "Grundsteuer", "Einkommen",
        "Erklärung", "Beleg", "Quittung", "Gebühr", "Größe", "Maß", "Fuß", "Grüße", "invoice", "payment", "amount",
        "due", "contract", "insurance", "policy", "claim", "account", "statement", "balance", "tax", "return",
        "refund", "order", "delivery", "warranty", "receipt", "customer", "number", "date", "total", "please",
        "thank", "unser", "bitte", "Sehr", "geehrte", "Damen", "Herren", "freundlichen", "Grüßen", "Telefon",
        "Adresse", "München", "Köln", "Hamburg", "Berlin", "Müller", "Mueller", "Schmidt", "Schneider", "Fischer",
        "Weber", "Meyer", "Wagner", "Becker", "Schulz", "Hoffmann", "Schäfer", "Schaefer", "Köhler", "Koehler",
        "Telekom", "Vodafone", "Allianz", "Sparkasse", "Volksbank", "Januar", "Februar", "März", "April", "Mai",
        "Juni", "Juli", "August", "September", "Oktober", "November", "Dezember", "Jahr", "Monat", "Woche",
        "Beitrag", "Mitglied", "Verein", "Termin", "Antrag", "Genehmigung", "Wartung", "Heizung", "Reparatur",
        "Handwerker", "Angebot", "Kosten", "Preis", "Netto", "Brutto", "Mehrwertsteuer", "Umsatzsteuer", "Position",
        "Menge", "Einheit", "Seite", "Anlage", "Kopie", "Original", "Unterschrift", "Café", "Øresund", "œuvre",
    ]
}
