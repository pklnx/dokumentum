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
    /// its references and links but never a raw value (I8). Here the Kit planner and applier run on a snapshot
    /// read from the store; `noSwiftDataRepairPassWritesAFallbackBack` runs the SwiftData passes.
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

    /// The same on the store, rerun on the SwiftData passes (#30): every one of the five passes changes a
    /// document holding unknown raw values, which are still in the store afterwards, read from a fresh context.
    @Test func noSwiftDataRepairPassWritesAFallbackBack() async throws {
        let store = try TemporaryStore()
        defer { store.remove() }
        var unknown = document(1, correspondent: 10, tags: [20, 21, 23])
        (unknown.sourceRaw, unknown.processingStateRaw, unknown.textSourceRaw) = ("fax", "queued", "braille")
        try store.seed(
            RepairSnapshot(
                documents: [unknown],
                metadata: [
                    // Pass 1: a tombstone reference. Pass 2: two tags named "Tax". Pass 3: a cycle 22 ↔ 23.
                    correspondent(10, "Old", mergedInto: 11), correspondent(11, "New"),
                    tag(20, "Tax"), tag(21, "tax"), tag(22, "A", parent: 23), tag(23, "B", parent: 22),
                    // Pass 5: a loop of tombstones, also referenced by the document.
                    metadata(.documentType, 30, "X", mergedInto: 31), metadata(.documentType, 31, "Y", mergedInto: 30),
                ],
                blobs: [blob(.text, 40, documentID: 1)]))

        let repair = try await CheckedRepair.run(store)
        let passes = Set(repair.report.passes.filter { !$0.applied.isEmpty }.map(\.pass))
        #expect(passes == Set(RepairPass.allCases), "every pass changed something: \(repair.report.passes)")
        let stored = try #require(
            try ModelContext(store.container).fetch(FetchDescriptor<Document>()).first { $0.instanceID == uuid(1) })
        #expect(stored.correspondent?.instanceID == uuid(11))
        #expect(stored.text?.instanceID == uuid(40))
        #expect([stored.sourceRaw, stored.processingStateRaw, stored.textSourceRaw] == ["fax", "queued", "braille"])
    }
}
