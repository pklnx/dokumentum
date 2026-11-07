import Foundation

/// A record the repair can pick as a winner. `createdAt` and `instanceID` are set at insert and never
/// change, so the order they give is the same on every device (I5).
public protocol KeeperOrdered {
    var createdAt: Date { get }
    var instanceID: UUID { get }
}

/// The kinds of metadata that merge by name and can become tombstones.
public enum MetadataKind: String, Hashable, Sendable, CaseIterable {
    case correspondent
    case documentType
    case tag
}

/// The kinds of large-data record that belong to a document: one each per document, linked through a
/// to-one relationship of `Document`.
public enum BlobKind: String, Hashable, Sendable, CaseIterable {
    /// `DocumentFile`, the PDF.
    case file
    /// `DocumentThumbnail`.
    case thumbnail
    /// `DocumentText`, the extracted text.
    case text
}

/// A document as the repair sees it. Records are named by `instanceID`, because records can share an `id`.
public struct DocumentSnapshot: Hashable, Sendable, KeeperOrdered {
    public var instanceID: UUID
    public var id: UUID
    public var createdAt: Date
    /// Mutable, so no decision reads it (I5). `apply` touches it like the store does.
    public var modifiedAt: Date
    /// `instanceID` of the referenced correspondent.
    public var correspondent: UUID?
    /// `instanceID` of the referenced document type.
    public var documentType: UUID?
    /// `instanceID`s of the referenced tags.
    public var tags: Set<UUID>
    /// The frozen enums as stored. Only here so that `RepairInvariants` can see they stay as they are (I8).
    public var sourceRaw: String
    public var textSourceRaw: String
    public var processingStateRaw: String
    /// The kinds of which this document holds a linked blob that the snapshot does not list in `blobs`. The
    /// store reads them from the document row (`file != nil` and so on), so a repair run never loads a linked
    /// blob; every function here treats such a kind like a listed blob linked to this document. Only states
    /// the store can hold are meaningful: a kind here has no listed blob linked to this document.
    public var linkedBlobs: Set<BlobKind>

    public init(
        instanceID: UUID,
        id: UUID,
        createdAt: Date,
        modifiedAt: Date,
        correspondent: UUID? = nil,
        documentType: UUID? = nil,
        tags: Set<UUID> = [],
        sourceRaw: String = "file",
        textSourceRaw: String = "",
        processingStateRaw: String = "pending",
        linkedBlobs: Set<BlobKind> = []
    ) {
        self.instanceID = instanceID
        self.id = id
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.correspondent = correspondent
        self.documentType = documentType
        self.tags = tags
        self.sourceRaw = sourceRaw
        self.textSourceRaw = textSourceRaw
        self.processingStateRaw = processingStateRaw
        self.linkedBlobs = linkedBlobs
    }
}

/// A tag, correspondent or document type as the repair sees it.
public struct MetadataSnapshot: Hashable, Sendable, KeeperOrdered {
    public var kind: MetadataKind
    public var instanceID: UUID
    public var id: UUID
    public var createdAt: Date
    public var mergedAt: Date?
    public var name: String
    /// `instanceID` of the parent tag; always `nil` for correspondents and document types.
    public var parentInstanceID: UUID?
    /// The `id` (not the `instanceID`) of the record this one was merged into. Set means tombstone.
    public var mergedIntoID: UUID?

    public init(
        kind: MetadataKind,
        instanceID: UUID,
        id: UUID,
        createdAt: Date,
        mergedAt: Date? = nil,
        name: String,
        parentInstanceID: UUID? = nil,
        mergedIntoID: UUID? = nil
    ) {
        self.kind = kind
        self.instanceID = instanceID
        self.id = id
        self.createdAt = createdAt
        self.mergedAt = mergedAt
        self.name = name
        self.parentInstanceID = parentInstanceID
        self.mergedIntoID = mergedIntoID
    }

    /// "Live" means not merged away. Tombstones stay hidden and are never deleted in #2.
    public var isLive: Bool { mergedIntoID == nil }
}

/// A `DocumentFile`, `DocumentThumbnail` or `DocumentText` as the repair sees it.
public struct BlobSnapshot: Hashable, Sendable, KeeperOrdered {
    public var kind: BlobKind
    public var instanceID: UUID
    public var createdAt: Date
    /// The owning document's `id`, set at insert and never changed.
    public var documentID: UUID?
    /// `instanceID` of the document it is linked to; `nil` until CloudKit or the repair links it.
    public var linkedDocumentInstanceID: UUID?

    public init(
        kind: BlobKind,
        instanceID: UUID,
        createdAt: Date,
        documentID: UUID?,
        linkedDocumentInstanceID: UUID? = nil
    ) {
        self.kind = kind
        self.instanceID = instanceID
        self.createdAt = createdAt
        self.documentID = documentID
        self.linkedDocumentInstanceID = linkedDocumentInstanceID
    }
}

/// What one device holds at one moment: the input of every planner function.
public struct RepairSnapshot: Hashable, Sendable {
    public var documents: [DocumentSnapshot]
    public var metadata: [MetadataSnapshot]
    public var blobs: [BlobSnapshot]

    public init(
        documents: [DocumentSnapshot] = [],
        metadata: [MetadataSnapshot] = [],
        blobs: [BlobSnapshot] = []
    ) {
        self.documents = documents
        self.metadata = metadata
        self.blobs = blobs
    }
}

/// What the planner reads besides the records.
public struct RepairContext: Hashable, Sendable {
    public var now: Date
    /// Whether this device has completed a successful CloudKit import in the current app session.
    public var hasCompletedImport: Bool

    public init(now: Date, hasCompletedImport: Bool) {
        self.now = now
        self.hasCompletedImport = hasCompletedImport
    }
}
