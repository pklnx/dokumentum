import DokumentumCore
import DokumentumCoreTestSupport
import DokumentumKit
import DokumentumTestSupport
import Foundation
import SwiftData
import Testing

/// The frozen enums on the model: an unknown value from a newer build reads as its fallback and is never
/// written back (`CLAUDE.md`, "Synced enums").
@MainActor
struct FrozenEnumModelTests {
    private func unknownDocument() -> Document {
        let document = Document(title: "From a newer build")
        document.sourceRaw = "fax"
        document.processingStateRaw = "queued"
        document.textSourceRaw = "braille"
        return document
    }

    @Test func unknownValuesReadAsTheirFallback() {
        let document = unknownDocument()
        #expect(document.source == .file)
        #expect(document.processingState == .unknown)
        #expect(document.textSource == .unknown)
    }

    @Test func theSettersWriteTheStoredValue() {
        let document = Document()
        document.source = .scan
        document.processingState = .done
        document.textSource = .vision
        #expect(document.sourceRaw == "scan")
        #expect(document.processingStateRaw == "done")
        #expect(document.textSourceRaw == "vision")
        document.textSource = .none
        #expect(document.textSourceRaw == "")
        // An unknown value is replaced by a real new one.
        let unknown = unknownDocument()
        unknown.source = .image
        unknown.processingState = .pending
        unknown.textSource = .pdfText
        #expect(
            [unknown.sourceRaw, unknown.processingStateRaw, unknown.textSourceRaw] == ["image", "pending", "pdfText"])
    }

    /// Setting the value a document already reads as, or `.unknown`, keeps the stored string: "fax" is not
    /// turned into "file".
    @Test func settingTheFallbackWritesNothing() {
        let document = unknownDocument()
        document.source = document.source
        document.source = .file
        document.processingState = .unknown
        document.processingState = document.processingState
        document.textSource = .unknown
        #expect(document.sourceRaw == "fax")
        #expect(document.processingStateRaw == "queued")
        #expect(document.textSourceRaw == "braille")
    }

    /// An unrelated edit, a save and a reopen keep the unknown raw values.
    @Test func unknownValuesSurviveAnEditAndAReopen() throws {
        let url = try TestSupport.makeTemporaryDirectory().appending(path: "Frozen.store")
        let instance: UUID
        do {
            let container = try TestSupport.makeContainerOnDisk(at: url)
            let context = ModelContext(container)
            let document = unknownDocument()
            instance = document.instanceID
            context.insert(document)
            try context.save()
            let again = ModelContext(container)
            let stored = try #require(try again.fetch(FetchDescriptor<Document>()).first { $0.instanceID == instance })
            stored.title = "Edited"
            stored.touch()
            try again.save()
        }
        let reopened = try TestSupport.makeContainerOnDisk(at: url)
        let read = try #require(
            try ModelContext(reopened).fetch(FetchDescriptor<Document>()).first { $0.instanceID == instance })
        #expect(read.title == "Edited")
        #expect(read.sourceRaw == "fax")
        #expect(read.processingStateRaw == "queued")
        #expect(read.textSourceRaw == "braille")
    }

    /// Every repair pass on a store holding such a document: the plan made from the store's snapshot changes
    /// its references and links but never a raw value (I8). The SwiftData passes arrive with #2's part 3, which
    /// reruns this on the store; here the Kit planner and applier run on a snapshot read from the store.
    @Test func noRepairPassWritesAFallbackBack() throws {
        let container = try TestSupport.makeContainer()
        let context = ModelContext(container)
        let live = Correspondent(name: "Stadtwerke")
        let tombstone = Correspondent(name: "Stadtwerke")
        context.insert(live)
        context.insert(tombstone)
        tombstone.mergedIntoID = live.id
        tombstone.mergedAt = Date(timeIntervalSinceReferenceDate: 0)
        let document = unknownDocument()
        context.insert(document)
        document.correspondent = tombstone
        // A text that arrived before its document's link: pass 4 relinks it.
        context.insert(DocumentText(documentID: document.id))
        try context.save()

        let before = try RepairSnapshotReader.full(of: ModelContext(container))
        let plan = RepairPlanner.plan(before, context: RepairContext(now: Date(), hasCompletedImport: true))
        #expect(plan.operations.count == 2, "a re-point and a relink: \(plan.operations)")
        let after = plan.apply(to: before, now: Date()).snapshot
        #expect(RepairInvariants.violations(before: before, plan: plan, after: after).isEmpty)
        let repaired = try #require(after.documents.first { $0.instanceID == document.instanceID })
        #expect(repaired.correspondent == live.instanceID)
        #expect(
            [repaired.sourceRaw, repaired.processingStateRaw, repaired.textSourceRaw] == ["fax", "queued", "braille"])
    }
}

/// Builds the repair's full snapshot (every blob listed) from a store, for tests.
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
