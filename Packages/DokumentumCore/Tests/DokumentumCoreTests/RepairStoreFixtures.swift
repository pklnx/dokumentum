import DokumentumCore
import DokumentumCoreTestSupport
import DokumentumKit
import DokumentumTestSupport
import Foundation
import SwiftData
import Testing

// The repair tests' tools: a store on disk in a temporary folder that the test removes, a seeder that writes a
// `RepairSnapshot` into a store record by record, and the full snapshot read back for `RepairInvariants`. The
// snapshot builders follow DokumentumKit's `RepairTestSupport`, so a case reads the same in both packages.

/// A readable, fixed UUID: its `uuidString` sorts by `n`.
func uuid(_ n: Int) -> UUID {
    UUID(uuidString: String(format: "00000000-0000-0000-0000-%012X", n))!
}

/// Seconds, so that test dates read as an order. Whole seconds survive the store's round trip exactly.
func at(_ seconds: Int) -> Date {
    Date(timeIntervalSince1970: TimeInterval(seconds))
}

let days = 24 * 60 * 60
/// The time of every repair run in these tests: after the dates they use.
let repairTime = at(1000 * days)

/// Metadata whose `id` is `instance + 1000`, unless a test wants them to share one.
func metadata(
    _ kind: MetadataKind, _ instance: Int, _ name: String, created: Int? = nil, id: Int? = nil, parent: Int? = nil,
    mergedInto: Int? = nil, mergedAt: Date? = nil
) -> MetadataSnapshot {
    MetadataSnapshot(
        kind: kind, instanceID: uuid(instance), id: uuid(id ?? instance + 1000), createdAt: at(created ?? instance),
        mergedAt: mergedAt ?? (mergedInto == nil ? nil : at(0)), name: name, parentInstanceID: parent.map(uuid),
        mergedIntoID: mergedInto.map { uuid($0 + 1000) })
}

func tag(
    _ instance: Int, _ name: String, created: Int? = nil, id: Int? = nil, parent: Int? = nil, mergedInto: Int? = nil,
    mergedAt: Date? = nil
) -> MetadataSnapshot {
    metadata(.tag, instance, name, created: created, id: id, parent: parent, mergedInto: mergedInto, mergedAt: mergedAt)
}

func correspondent(
    _ instance: Int, _ name: String, created: Int? = nil, id: Int? = nil, mergedInto: Int? = nil, mergedAt: Date? = nil
) -> MetadataSnapshot {
    metadata(.correspondent, instance, name, created: created, id: id, mergedInto: mergedInto, mergedAt: mergedAt)
}

func document(
    _ instance: Int, id: Int? = nil, created: Int? = nil, modified: Int = 0, correspondent: Int? = nil,
    type: Int? = nil, tags: [Int] = []
) -> DocumentSnapshot {
    DocumentSnapshot(
        instanceID: uuid(instance), id: uuid(id ?? instance + 1000), createdAt: at(created ?? instance),
        modifiedAt: at(modified), correspondent: correspondent.map(uuid), documentType: type.map(uuid),
        tags: Set(tags.map(uuid)))
}

func blob(_ kind: BlobKind, _ instance: Int, created: Int? = nil, documentID: Int?, linkedTo: Int? = nil)
    -> BlobSnapshot
{
    BlobSnapshot(
        kind: kind, instanceID: uuid(instance), createdAt: at(created ?? instance),
        documentID: documentID.map { uuid($0 + 1000) }, linkedDocumentInstanceID: linkedTo.map(uuid))
}

extension RepairSnapshot {
    func record(_ instance: Int) -> MetadataSnapshot? { metadata.first { $0.instanceID == uuid(instance) } }
    func document(_ instance: Int) -> DocumentSnapshot? { documents.first { $0.instanceID == uuid(instance) } }
    func blob(_ instance: Int) -> BlobSnapshot? { blobs.first { $0.instanceID == uuid(instance) } }

    /// Sorted by `instanceID`, so two reads of the same data compare equal whatever the fetch order.
    var sorted: RepairSnapshot {
        RepairSnapshot(
            documents: documents.sorted { $0.instanceID.uuidString < $1.instanceID.uuidString },
            metadata: metadata.sorted { $0.instanceID.uuidString < $1.instanceID.uuidString },
            blobs: blobs.sorted { $0.instanceID.uuidString < $1.instanceID.uuidString })
    }

    /// The convergence test's canonical dump: sorted, without `modifiedAt` and `mergedAt`, the two values that
    /// carry the time of a device's own run.
    var canonical: RepairSnapshot {
        var result = sorted
        for index in result.documents.indices { result.documents[index].modifiedAt = at(0) }
        for index in result.metadata.indices where result.metadata[index].mergedAt != nil {
            result.metadata[index].mergedAt = at(0)
        }
        return result
    }
}

/// A store on disk in a temporary folder of its own, removed by `remove()` at the end of the test (`defer`).
/// The container stays alive until the end of the run (`ContainerKeeper`); nothing writes to it after its
/// test, so the removed files are not missed.
struct TemporaryStore {
    let folder: URL
    let container: ModelContainer

    init() throws {
        folder = try TestSupport.makeTemporaryDirectory()
        container = try TestSupport.makeContainerOnDisk(at: folder.appending(path: "Repair.store"))
    }

    func remove() {
        // Only the folder `makeTemporaryDirectory()` made.
        guard folder.lastPathComponent.hasPrefix("DokumentumTests-"),
            folder.deletingLastPathComponent().standardizedFileURL
                == FileManager.default.temporaryDirectory.standardizedFileURL
        else { return }
        try? FileManager.default.removeItem(at: folder)
    }

    /// The full snapshot (every blob listed), as `RepairInvariants` needs it.
    func full() throws -> RepairSnapshot {
        try RepairSnapshotReader.full(of: ModelContext(container))
    }

    func seed(_ snapshot: RepairSnapshot, order seed: Int? = nil) throws {
        try StoreSeeder.insert(snapshot, into: container, order: seed)
    }

    /// One run through `RepairRunner`, at `repairTime`.
    func repair(hasCompletedImport: Bool = true) async throws -> RepairReport {
        try #require(
            await RepairRunner(modelContainer: container, clock: { repairTime }).run(
                hasCompletedImport: hasCompletedImport))
    }
}

/// One repaired store with the checks every repair test makes: `RepairInvariants` on the store's full
/// snapshots before and after, the run's plan equal to the plan `RepairPlanner` makes for the whole state, and
/// the store ending exactly where the planner's simulation ends (`RepairPlan.apply`), `modifiedAt` and
/// `mergedAt` included.
struct CheckedRepair {
    let before: RepairSnapshot
    let report: RepairReport
    let after: RepairSnapshot

    var plan: RepairPlan { report.plan }

    static func run(
        _ store: TemporaryStore, hasCompletedImport: Bool = true, sourceLocation: SourceLocation = #_sourceLocation
    ) async throws -> CheckedRepair {
        let before = try store.full()
        let report = try await store.repair(hasCompletedImport: hasCompletedImport)
        let after = try store.full()
        let violations = RepairInvariants.violations(before: before, plan: report.plan, after: after)
        #expect(violations.isEmpty, "\(violations)", sourceLocation: sourceLocation)
        #expect(report.skipped.isEmpty, "skipped without a concurrent edit", sourceLocation: sourceLocation)
        let context = RepairContext(now: repairTime, hasCompletedImport: hasCompletedImport)
        let expected = RepairPlanner.plan(before, context: context)
        #expect(report.plan == expected, "the store's run planned otherwise", sourceLocation: sourceLocation)
        let simulated = expected.apply(to: before, now: repairTime).snapshot
        #expect(after.sorted == simulated.sorted, "the store ended elsewhere", sourceLocation: sourceLocation)
        return CheckedRepair(before: before, report: report, after: after)
    }
}

/// Writes a snapshot into a store as records with exactly its values (`id`, `instanceID`, dates, names,
/// references, links). Records already in the store can be referenced. `order` shuffles the insertion order
/// with a seed; `nil` keeps the snapshot's order.
enum StoreSeeder {
    static func insert(_ snapshot: RepairSnapshot, into container: ModelContainer, order seed: Int? = nil) throws {
        let context = ModelContext(container)
        var generator = SeededGenerator(seed: UInt64(seed ?? 0))  // LibraryMappingTests
        func ordered<T>(_ items: [T]) -> [T] { seed == nil ? items : items.shuffled(using: &generator) }

        var tags = Dictionary(
            try context.fetch(FetchDescriptor<DokumentumCore.Tag>()).map { ($0.instanceID, $0) },
            uniquingKeysWith: { a, _ in a })
        var correspondents = Dictionary(
            try context.fetch(FetchDescriptor<Correspondent>()).map { ($0.instanceID, $0) },
            uniquingKeysWith: { a, _ in a })
        var types = Dictionary(
            try context.fetch(FetchDescriptor<DocumentType>()).map { ($0.instanceID, $0) },
            uniquingKeysWith: { a, _ in a })
        var documents = Dictionary(
            try context.fetch(FetchDescriptor<Document>()).map { ($0.instanceID, $0) },
            uniquingKeysWith: { a, _ in a })

        for record in ordered(snapshot.metadata) {
            switch record.kind {
            case .tag:
                let tag = DokumentumCore.Tag(name: record.name, createdAt: record.createdAt)
                (tag.id, tag.instanceID, tag.mergedIntoID, tag.mergedAt) =
                    (record.id, record.instanceID, record.mergedIntoID, record.mergedAt)
                context.insert(tag)
                tags[record.instanceID] = tag
            case .correspondent:
                let correspondent = Correspondent(name: record.name, createdAt: record.createdAt)
                (correspondent.id, correspondent.instanceID, correspondent.mergedIntoID, correspondent.mergedAt) =
                    (record.id, record.instanceID, record.mergedIntoID, record.mergedAt)
                context.insert(correspondent)
                correspondents[record.instanceID] = correspondent
            case .documentType:
                let type = DocumentType(name: record.name, createdAt: record.createdAt)
                (type.id, type.instanceID, type.mergedIntoID, type.mergedAt) =
                    (record.id, record.instanceID, record.mergedIntoID, record.mergedAt)
                context.insert(type)
                types[record.instanceID] = type
            }
        }
        for record in snapshot.metadata where record.kind == .tag {
            tags[record.instanceID]?.parent = try record.parentInstanceID.map { try #require(tags[$0]) }
        }
        for record in ordered(snapshot.documents) {
            let document = Document(id: record.id, title: "Document", createdAt: record.createdAt)
            document.instanceID = record.instanceID
            context.insert(document)
            document.modifiedAt = record.modifiedAt
            (document.sourceRaw, document.textSourceRaw, document.processingStateRaw) =
                (record.sourceRaw, record.textSourceRaw, record.processingStateRaw)
            document.correspondent = try record.correspondent.map { try #require(correspondents[$0]) }
            document.documentType = try record.documentType.map { try #require(types[$0]) }
            document.tags = try record.tags.map { try #require(tags[$0]) }
            documents[record.instanceID] = document
        }
        for record in ordered(snapshot.blobs) {
            let linked = try record.linkedDocumentInstanceID.map { try #require(documents[$0]) }
            switch record.kind {
            case .file:
                let file = DocumentFile(
                    documentID: record.documentID, pdfData: Data("%PDF".utf8), createdAt: record.createdAt)
                file.instanceID = record.instanceID
                context.insert(file)
                file.document = linked
            case .thumbnail:
                let thumbnail = DocumentThumbnail(
                    documentID: record.documentID, imageData: Data([1, 2, 3]), createdAt: record.createdAt)
                thumbnail.instanceID = record.instanceID
                context.insert(thumbnail)
                thumbnail.document = linked
            case .text:
                let text = DocumentText(
                    documentID: record.documentID, extractedText: "Text", createdAt: record.createdAt)
                text.instanceID = record.instanceID
                context.insert(text)
                text.document = linked
            }
        }
        try context.save()
    }
}

/// Builds the repair's full snapshot (every blob listed, linked ones too) from a store, for tests. The repair
/// itself reads the light form (`RepairStore`).
enum RepairSnapshotReader {
    static func full(of context: ModelContext) throws -> RepairSnapshot {
        let documents = try context.fetch(FetchDescriptor<Document>()).map { document in
            DocumentSnapshot(
                instanceID: document.instanceID, id: document.id, createdAt: document.createdAt,
                modifiedAt: document.modifiedAt, correspondent: document.correspondent?.instanceID,
                documentType: document.documentType?.instanceID,
                tags: Set((document.tags ?? []).map(\.instanceID)), sourceRaw: document.sourceRaw,
                textSourceRaw: document.textSourceRaw, processingStateRaw: document.processingStateRaw)
        }
        var metadata = try context.fetch(FetchDescriptor<Correspondent>()).map {
            MetadataSnapshot(
                kind: .correspondent, instanceID: $0.instanceID, id: $0.id, createdAt: $0.createdAt,
                mergedAt: $0.mergedAt, name: $0.name, mergedIntoID: $0.mergedIntoID)
        }
        metadata += try context.fetch(FetchDescriptor<DocumentType>()).map {
            MetadataSnapshot(
                kind: .documentType, instanceID: $0.instanceID, id: $0.id, createdAt: $0.createdAt,
                mergedAt: $0.mergedAt, name: $0.name, mergedIntoID: $0.mergedIntoID)
        }
        metadata += try context.fetch(FetchDescriptor<DokumentumCore.Tag>()).map {
            MetadataSnapshot(
                kind: .tag, instanceID: $0.instanceID, id: $0.id, createdAt: $0.createdAt, mergedAt: $0.mergedAt,
                name: $0.name, parentInstanceID: $0.parent?.instanceID, mergedIntoID: $0.mergedIntoID)
        }
        var blobs = try context.fetch(FetchDescriptor<DocumentFile>()).map {
            BlobSnapshot(
                kind: .file, instanceID: $0.instanceID, createdAt: $0.createdAt, documentID: $0.documentID,
                linkedDocumentInstanceID: $0.document?.instanceID)
        }
        blobs += try context.fetch(FetchDescriptor<DocumentThumbnail>()).map {
            BlobSnapshot(
                kind: .thumbnail, instanceID: $0.instanceID, createdAt: $0.createdAt, documentID: $0.documentID,
                linkedDocumentInstanceID: $0.document?.instanceID)
        }
        blobs += try context.fetch(FetchDescriptor<DocumentText>()).map {
            BlobSnapshot(
                kind: .text, instanceID: $0.instanceID, createdAt: $0.createdAt, documentID: $0.documentID,
                linkedDocumentInstanceID: $0.document?.instanceID)
        }
        return RepairSnapshot(documents: documents, metadata: metadata, blobs: blobs)
    }
}
