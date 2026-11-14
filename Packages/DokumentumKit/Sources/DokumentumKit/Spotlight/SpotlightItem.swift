import Foundation

/// The limits of what the app gives Spotlight (#13, plan §1 and §3, T12).
public enum SpotlightLimits {
    /// `textContent` is the head of the recognised text, at most this many UTF-8 bytes (N3). The stored text is at most
    /// 500,000 bytes (#6, T7). Part of the item format: a change bumps `SpotlightItem.formatVersion`.
    public static let textBytes = 200_000
    /// A batch of upserts holds at most this many items …
    public static let batchItems = 100
    /// … and at most this many bytes of `textContent`.
    public static let batchTextBytes = 4_000_000
    /// A batch of deletes names at most this many identifiers.
    public static let deleteBatch = 500
}

/// One document as Spotlight gets it (#13, plan §1; Q1): plain values, so the engine and its tests never touch
/// CoreSpotlight. Part 2's `SystemSpotlightIndex` maps it to a `CSSearchableItem`.
public struct SpotlightItem: Sendable, Hashable {
    /// The version of the mapping from a document to an item. **Bump it with every change of the mapping**, a new field
    /// read or a new cap included: a stored state of another version triggers a full re-index.
    public static let formatVersion = 1
    /// The app's one domain (`domainIdentifier`).
    public static let domain = "documents"
    /// `UTType.pdf`.
    public static let contentType = "com.adobe.pdf"

    /// The document's `instanceID`, the app's handle of a document (T2).
    public var identifier: String
    public var domainIdentifier: String
    public var contentType: String
    /// `nil` would leave the system's default, one month, after which an item drops out of Spotlight silently; the
    /// mapping sets `Date.distantFuture`.
    public var expirationDate: Date?
    /// The display title, "Untitled document" (localized) for an empty one.
    public var title: String
    /// What a result shows under its title: correspondent · type · document date. Never text of the document (Q1).
    public var contentDescription: String
    /// The correspondent, the type and every tag's display path.
    public var keywords: [String]
    /// The head of the recognised text (`SpotlightLimits.textBytes`): searchable, never shown (Q1).
    public var textContent: String
    /// The document date.
    public var contentCreationDate: Date
    /// `createdAt`.
    public var addedDate: Date
    /// `modifiedAt`.
    public var contentModificationDate: Date
    /// The stored thumbnail (a JPEG), when there is one.
    public var thumbnailData: Data?

    public init(
        identifier: String, domainIdentifier: String = SpotlightItem.domain,
        contentType: String = SpotlightItem.contentType, expirationDate: Date? = nil, title: String,
        contentDescription: String = "", keywords: [String] = [], textContent: String = "",
        contentCreationDate: Date, addedDate: Date, contentModificationDate: Date, thumbnailData: Data? = nil
    ) {
        self.identifier = identifier
        self.domainIdentifier = domainIdentifier
        self.contentType = contentType
        self.expirationDate = expirationDate
        self.title = title
        self.contentDescription = contentDescription
        self.keywords = keywords
        self.textContent = textContent
        self.contentCreationDate = contentCreationDate
        self.addedDate = addedDate
        self.contentModificationDate = contentModificationDate
        self.thumbnailData = thumbnailData
    }
}

/// The metadata of one live document that its item and its fingerprint are made of (#13, plan §1 and §3): what the
/// light list query gives, with the copy `RowRecords.oldestFirst` keeps.
public struct SpotlightDocument: Sendable, Hashable {
    public var instanceID: UUID
    public var title: String
    public var correspondent: String
    public var documentType: String
    /// Sorted.
    public var tagPaths: [String]
    public var documentDate: Date
    public var createdAt: Date
    public var modifiedAt: Date
    public var isInbox: Bool

    public init(
        instanceID: UUID, title: String, correspondent: String = "", documentType: String = "",
        tagPaths: [String] = [], documentDate: Date, createdAt: Date, modifiedAt: Date, isInbox: Bool
    ) {
        self.instanceID = instanceID
        self.title = title
        self.correspondent = correspondent
        self.documentType = documentType
        self.tagPaths = tagPaths.sorted()
        self.documentDate = documentDate
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.isInbox = isInbox
    }

    /// The canonical bytes a fingerprint is made of, with the item format version: every field length-prefixed, dates
    /// by their bit pattern, so equal documents give equal bytes on every run.
    public func canonicalBytes(formatVersion: Int) -> Data {
        var data = Data()
        func append(_ text: String) {
            let bytes = Array(text.utf8)
            data.append(contentsOf: Array("\(bytes.count):".utf8))
            data.append(contentsOf: bytes)
        }
        func append(_ date: Date) { append(String(date.timeIntervalSinceReferenceDate.bitPattern, radix: 16)) }
        append("spotlight-item-v\(formatVersion)")
        append(instanceID.uuidString)
        append(title)
        append(correspondent)
        append(documentType)
        append("\(tagPaths.count)")
        for path in tagPaths { append(path) }
        append(documentDate)
        append(createdAt)
        append(modifiedAt)
        append(isInbox ? "inbox" : "filed")
        return data
    }
}

extension SpotlightItem {
    /// What the mapping needs from the app: Kit emits no strings of its own.
    public struct Strings: Sendable {
        /// "Untitled document", localized.
        public var untitledTitle: String
        /// The locale of the description's date (medium).
        public var locale: Locale

        public init(untitledTitle: String, locale: Locale) {
            self.untitledTitle = untitledTitle
            self.locale = locale
        }
    }

    /// The item of `document`, with the text and thumbnail of the copy it was read from.
    public init(_ document: SpotlightDocument, text: String, thumbnail: Data?, strings: Strings) {
        let title = normalizedTitle(document.title)
        let date = document.documentDate.formatted(
            Date.FormatStyle(date: .abbreviated, time: .omitted).locale(strings.locale))
        let parts = [document.correspondent, document.documentType, date].filter { !isBlank($0) }
        let keywords = ([document.correspondent, document.documentType] + document.tagPaths).filter { !isBlank($0) }
        self.init(
            identifier: document.instanceID.uuidString, expirationDate: .distantFuture,
            title: title.isEmpty ? strings.untitledTitle : title, contentDescription: parts.joined(separator: " · "),
            keywords: keywords, textContent: TextBudget.head(of: text, maxBytes: SpotlightLimits.textBytes),
            contentCreationDate: document.documentDate, addedDate: document.createdAt,
            contentModificationDate: document.modifiedAt, thumbnailData: thumbnail)
    }
}

private func isBlank(_ text: String) -> Bool {
    text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
}
