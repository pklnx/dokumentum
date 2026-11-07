import Foundation
import SwiftData

/// The first synced schema (1.0.0). It becomes the CloudKit schema of the private database, so the
/// CloudKit rules hold for every model (`SchemaTests` checks them, `scripts/check-schema-snapshots.py`
/// compares the committed dumps):
/// - every attribute has a default or is optional;
/// - every relationship is optional and has an inverse;
/// - nothing is `@Attribute(.unique)`, and no delete rule is `deny`.
///
/// **Additive only.** Once a version is deployed to Production (`production-versions.txt`) it never changes.
/// A model change adds `DokumentumSchemaV<N>` with copies of the models, a lightweight stage in
/// `DokumentumMigrationPlan`, `schema-v<N>.txt` and a migration test (docs/development/index.md, "Data
/// model and sync"). The typealiases in `Model.swift` then move to the new version.
///
/// **`instanceID` and `createdAt`** are set at insert and never changed or copied: an import that keeps
/// a record's `id` still gives it a new `instanceID`. They are the keys of every repair winner
/// (`RepairPlanner.keeperOrder`), and `instanceID` is the handle of one record, because records can share
/// an `id` until step 16. They are in V1 because a migration cannot add them deterministically: each
/// device would generate its own values.
public enum DokumentumSchemaV1: VersionedSchema {
    public static let versionIdentifier = Schema.Version(1, 0, 0)

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
        @Relationship(deleteRule: .nullify)
        public var documents: [Document]? = []

        public init(name: String, createdAt: Date = Date()) {
            self.instanceID = UUID()
            self.name = name
            self.createdAt = createdAt
        }
    }
}
