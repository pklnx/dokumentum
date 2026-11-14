import Foundation
import SwiftData

/// The third synced schema (3.0.0): V2 with a document's deadline (#12, part 1). It adds five fields to
/// `Document`: `deadlineDay`, `deadlineLabel` and `deadlineDismissedDay` (`String`, default `""`), and `deadlineSetAt`
/// and `deadlineDoneAt` (`Date?`); nothing else changes. `DokumentumMigrationPlan` reaches it from V2 by one
/// lightweight stage, and `schema-v3.txt` differs from `schema-v2.txt` by added lines only
/// (`scripts/check-schema-snapshots.py`).
///
/// The models are copies of V2's; `DokumentumSchemaV1` holds the CloudKit rules, the additive-only rule and the
/// reasons for `instanceID` and `createdAt`, which hold here too. V1 and V2 stay as they are, so `StoreMigrationTests`
/// writes real V1 and V2 stores and opens them with this version. A change of V1 or V2 before it is deployed to
/// Production (release.md, M1, case C7) is made here identically, so every stage stays lightweight.
public enum DokumentumSchemaV3: VersionedSchema {
    public static let versionIdentifier = Schema.Version(3, 0, 0)

    public static var models: [any PersistentModel.Type] {
        [
            Document.self, DocumentFile.self, DocumentThumbnail.self, DocumentText.self, Tag.self, Correspondent.self,
            DocumentType.self,
        ]
    }

    /// One archived document: its metadata only. The PDF, the thumbnail and the extracted text are records of
    /// their own (`file`, `thumbnail`, `text`), so a list never loads them: SwiftData on 27 reads every column
    /// of a fetched entity and ignores `propertiesToFetch` (measured on #29), so a large field here would load
    /// with every list.
    @Model
    public final class Document {
        /// Not unique (CloudKit). Duplicates by `id` are counted by the repair, not merged, until step 16.
        public var id: UUID = UUID()
        public var instanceID: UUID = UUID()
        public var title: String = ""
        public var createdAt: Date = Date()
        /// Touched (`touch()`) by every user edit and every repair change to the document.
        public var modifiedAt: Date = Date()
        public var documentDate: Date = Date()
        public var isInbox: Bool = true
        public var pageCount: Int = 0
        public var fileSize: Int = 0
        /// Frozen enum `TextSource`; read and write it through `textSource`. On the document, not on its text
        /// record, so a row shows it without loading the text.
        public var textSourceRaw: String = ""
        /// Frozen enum `ProcessingState`; read and write it through `processingState`.
        public var processingStateRaw: String = "pending"
        /// The device that claimed the document for processing (step 3).
        public var processingDeviceID: String = ""
        public var processingClaimedAt: Date?
        /// SHA-256 of the original bytes (step 3).
        public var contentHash: String = ""
        public var originalFileName: String = ""
        /// Frozen enum `DocumentSource`; read and write it through `source`.
        public var sourceRaw: String = "file"
        /// Set while the document is in the trash (step 2).
        public var deletedAt: Date?
        /// The deadline's day (#12) as ISO 8601 `yyyy-MM-dd`; `""` is no deadline. Read it through `deadline`, which
        /// reads only the first ten characters (a later build may append a time) and never writes back a value it
        /// cannot read. A calendar day, not a `Date`: it has no time zone.
        public var deadlineDay: String = ""
        /// The deadline's optional short text ("Pay").
        public var deadlineLabel: String = ""
        /// When a user last set the day (#12, §3): a reminder never fires at the moment of entry.
        public var deadlineSetAt: Date?
        /// When the deadline was marked done; `nil` while it is open.
        public var deadlineDoneAt: Date?
        /// Due-date suggestions are dismissed up to this day (`yyyy-MM-dd`, the read rule of `deadlineDay`); `""` is
        /// none. Read it through `dismissedSuggestionDay`.
        public var deadlineDismissedDay: String = ""

        @Relationship(deleteRule: .nullify, inverse: \Correspondent.documents)
        public var correspondent: Correspondent?
        @Relationship(deleteRule: .nullify, inverse: \DocumentType.documents)
        public var documentType: DocumentType?
        @Relationship(deleteRule: .nullify, inverse: \Tag.documents)
        public var tags: [Tag]? = []
        /// `nil` while the file has not arrived through CloudKit yet ("still downloading").
        @Relationship(deleteRule: .cascade, inverse: \DocumentFile.document)
        public var file: DocumentFile?
        @Relationship(deleteRule: .cascade, inverse: \DocumentThumbnail.document)
        public var thumbnail: DocumentThumbnail?
        /// `nil` while the text record has not arrived through CloudKit yet.
        @Relationship(deleteRule: .cascade, inverse: \DocumentText.document)
        public var text: DocumentText?

        public init(id: UUID = UUID(), title: String = "", createdAt: Date = Date()) {
            self.id = id
            self.instanceID = UUID()
            self.title = title
            self.createdAt = createdAt
            self.modifiedAt = createdAt
            self.documentDate = createdAt
        }
    }

    /// The PDF of a document. Created once, at import; later steps (text layer) replace `pdfData` in place
    /// and never insert a second file for the same document.
    @Model
    public final class DocumentFile {
        public var id: UUID = UUID()
        public var instanceID: UUID = UUID()
        public var createdAt: Date = Date()
        /// The owning document's `id`, set at insert and never changed, so the repair can link a file that
        /// arrived before its document.
        public var documentID: UUID?
        @Attribute(.externalStorage)
        public var pdfData: Data?
        /// `nil` until CloudKit links it.
        public var document: Document?

        public init(documentID: UUID?, pdfData: Data?, createdAt: Date = Date()) {
            self.instanceID = UUID()
            self.documentID = documentID
            self.pdfData = pdfData
            self.createdAt = createdAt
        }
    }

    /// The thumbnail of a document; like `DocumentFile`, created once at import.
    @Model
    public final class DocumentThumbnail {
        public var id: UUID = UUID()
        public var instanceID: UUID = UUID()
        public var createdAt: Date = Date()
        /// The owning document's `id`, set at insert and never changed.
        public var documentID: UUID?
        @Attribute(.externalStorage)
        public var imageData: Data?
        /// `nil` until CloudKit links it.
        public var document: Document?

        public init(documentID: UUID?, imageData: Data?, createdAt: Date = Date()) {
            self.instanceID = UUID()
            self.documentID = documentID
            self.imageData = imageData
            self.createdAt = createdAt
        }
    }

    /// The extracted text of a document. Created once, at import, by the importing device, with an empty
    /// `extractedText` and in the same save as its document; processing writes `extractedText` in place and
    /// never inserts a second text (docs/development/index.md, "Data model and sync").
    @Model
    public final class DocumentText {
        public var id: UUID = UUID()
        public var instanceID: UUID = UUID()
        public var createdAt: Date = Date()
        /// The owning document's `id`, set at insert and never changed.
        public var documentID: UUID?
        /// A plain attribute: external storage applies to `Data` only.
        public var extractedText: String = ""
        /// `nil` until CloudKit links it.
        public var document: Document?

        public init(documentID: UUID?, extractedText: String = "", createdAt: Date = Date()) {
            self.instanceID = UUID()
            self.documentID = documentID
            self.extractedText = extractedText
            self.createdAt = createdAt
        }
    }

    /// A tag; tags nest through `parent`.
    @Model
    public final class Tag {
        public var id: UUID = UUID()
        public var instanceID: UUID = UUID()
        public var name: String = ""
        public var colorHex: String = "#3B82F6"
        public var createdAt: Date = Date()
        /// Set when the repair merged this tag into another (that tag's `id`): a hidden tombstone, never
        /// deleted in #2. Only the repair's revive rule clears it.
        public var mergedIntoID: UUID?
        /// When it became a tombstone.
        public var mergedAt: Date?
        /// Frozen enum `MatchMode` of this record's matching rule (#10); `""` is no rule. Read and write it
        /// through `matchMode`.
        public var matchModeRaw: String = ""
        /// The rule's words, phrase or regular expression, as the user typed it.
        public var matchPattern: String = ""
        @Relationship(deleteRule: .nullify, inverse: \Tag.children)
        public var parent: Tag?
        /// Nullify: when a tag is deleted, its children become roots.
        @Relationship(deleteRule: .nullify)
        public var children: [Tag]? = []
        @Relationship(deleteRule: .nullify)
        public var documents: [Document]? = []

        public init(name: String, createdAt: Date = Date()) {
            self.instanceID = UUID()
            self.name = name
            self.createdAt = createdAt
        }
    }

    /// Who sent a document.
    @Model
    public final class Correspondent {
        public var id: UUID = UUID()
        public var instanceID: UUID = UUID()
        public var name: String = ""
        public var createdAt: Date = Date()
        /// Tombstone, as on `Tag`.
        public var mergedIntoID: UUID?
        public var mergedAt: Date?
        /// The matching rule, as on `Tag`.
        public var matchModeRaw: String = ""
        /// The rule's words, phrase or regular expression, as the user typed it.
        public var matchPattern: String = ""
        @Relationship(deleteRule: .nullify)
        public var documents: [Document]? = []

        public init(name: String, createdAt: Date = Date()) {
            self.instanceID = UUID()
            self.name = name
            self.createdAt = createdAt
        }
    }

    /// What kind of document it is (invoice, contract, …).
    @Model
    public final class DocumentType {
        public var id: UUID = UUID()
        public var instanceID: UUID = UUID()
        public var name: String = ""
        public var createdAt: Date = Date()
        /// Tombstone, as on `Tag`.
        public var mergedIntoID: UUID?
        public var mergedAt: Date?
        /// The matching rule, as on `Tag`.
        public var matchModeRaw: String = ""
        /// The rule's words, phrase or regular expression, as the user typed it.
        public var matchPattern: String = ""
        @Relationship(deleteRule: .nullify)
        public var documents: [Document]? = []

        public init(name: String, createdAt: Date = Date()) {
            self.instanceID = UUID()
            self.name = name
            self.createdAt = createdAt
        }
    }
}
