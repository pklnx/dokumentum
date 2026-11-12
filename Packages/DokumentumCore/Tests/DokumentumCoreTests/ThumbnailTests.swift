import CoreGraphics
import DokumentumCoreTestSupport
import DokumentumKit
import DokumentumTestSupport
import Foundation
import ImageIO
import PDFKit
import SwiftData
import Synchronization
import Testing

@testable import DokumentumCore

/// The thumbnail (#6, part 4, T5, N3): made at import from page 1 (JPEG, 480 px on the long side) in the import's one
/// save; a render failure imports without one; processing inserts one only for a document the re-queue pass recorded
/// and only when none is linked, and prunes the record; nothing leaves an orphan thumbnail the repair would count.
struct ThumbnailTests {
    static let importTime = Date(timeIntervalSinceReferenceDate: 820_000_000)

    /// The pixel size of a JPEG.
    static func pixelSize(of data: Data) throws -> (width: Int, height: Int) {
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        #expect(CGImageSourceGetType(source) as String? == "public.jpeg")
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        return (image.width, image.height)
    }

    /// The repair's counts on the store: no orphan thumbnail and no document with two.
    static func expectNoOrphanThumbnails(
        _ container: ModelContainer, sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        let counts = try RepairRun.perform(in: container, now: importTime, hasCompletedImport: true).counts
        #expect(counts.orphanThumbnails == 0, sourceLocation: sourceLocation)
        #expect(counts.documentsWithTwoThumbnails == 0, sourceLocation: sourceLocation)
    }

    static func thumbnailCount(_ container: ModelContainer) throws -> Int {
        try ModelContext(container).fetchCount(FetchDescriptor<DocumentThumbnail>())
    }

    // MARK: At import

    @Test func aPDFImportLinksAThumbnailOfPage1InItsOneSave() async throws {
        let store = try TemporaryStore()
        defer { store.remove() }
        let saves = SaveCounter(store.container)
        // An A4 page: 480 px high, 339 px wide.
        let data = TestPDF.make(pages: ["Stadtwerke", "Seite zwei"])

        let outcome = await DocumentImporter(container: store.container, deviceID: deviceA, now: { Self.importTime })
            .importFile(data: data, fileName: "Rechnung.pdf")

        guard case .imported(let id) = outcome else {
            Issue.record("not imported: \(outcome)")
            return
        }
        #expect(saves.count == 1, "document, file, text and thumbnail in one save")
        let document = try #require(try ProcessingStore.fetch(id, in: ModelContext(store.container)))
        let thumbnail = try #require(document.thumbnail)
        #expect(thumbnail.documentID == document.id)
        #expect(thumbnail.createdAt == Self.importTime)
        let size = try Self.pixelSize(of: try #require(thumbnail.imageData))
        #expect(max(size.width, size.height) == Thumbnail.longSide)
        #expect(size.height == 480 && size.width == 339, "A4 portrait: \(size)")
        #expect(try Self.thumbnailCount(store.container) == 1)
        try Self.expectNoOrphanThumbnails(store.container)
    }

    /// Photos are built into a PDF first; the thumbnail is of that PDF's page 1, landscape here.
    @Test func anImageImportLinksAThumbnailToo() async throws {
        let container = try TestSupport.makeContainer()
        let outcome = await DocumentImporter(container: container, deviceID: deviceA)
            .importImages([TestImage.make(width: 800, height: 600)], fileName: "Foto.jpg")

        guard case .imported(let id) = outcome.outcome else {
            Issue.record("not imported: \(outcome)")
            return
        }
        let document = try #require(try ProcessingStore.fetch(id, in: ModelContext(container)))
        let size = try Self.pixelSize(of: try #require(document.thumbnail?.imageData))
        #expect(size.width == 480, "landscape: \(size)")
        #expect(size.height < size.width)
    }

    @Test func aRenderFailureImportsWithoutAThumbnail() async throws {
        let store = try TemporaryStore()
        defer { store.remove() }
        let rendered = Mutex(0)
        let importer = DocumentImporter(
            container: store.container, deviceID: deviceA,
            makeThumbnail: { _ in
                rendered.withLock { $0 += 1 }
                return nil
            })

        let outcome = await importer.importFile(data: TestPDF.make(pages: ["Seite"]), fileName: "Brief.pdf")

        guard case .imported(let id) = outcome else {
            Issue.record("not imported: \(outcome)")
            return
        }
        #expect(rendered.withLock { $0 } == 1)
        let document = try #require(try ProcessingStore.fetch(id, in: ModelContext(store.container)))
        #expect(document.thumbnail == nil)
        #expect(document.file?.pdfData != nil)
        #expect(document.text != nil)
        #expect(try Self.thumbnailCount(store.container) == 0)
        try Self.expectNoOrphanThumbnails(store.container)
    }

    /// A duplicate inserts nothing, the thumbnail neither.
    @Test func aDuplicateInsertsNoSecondThumbnail() async throws {
        let container = try TestSupport.makeContainer()
        let importer = DocumentImporter(container: container, deviceID: deviceA)
        let data = TestPDF.make(pages: ["Seite"])
        _ = await importer.importFile(data: data, fileName: "A.pdf")
        let second = await importer.importFile(data: data, fileName: "B.pdf")
        guard case .duplicate = second else {
            Issue.record("not a duplicate: \(second)")
            return
        }
        #expect(try Self.thumbnailCount(container) == 1)
    }

    @Test func aRotatedPageGivesARotatedThumbnail() throws {
        let document = try #require(PDFDocument(data: TestPDF.make(pages: ["Quer"])))
        try #require(document.page(at: 0)).rotation = 90
        let size = try Self.pixelSize(of: try #require(Thumbnail.make(from: document)))
        #expect(size.width == 480 && size.height == 339, "\(size)")
    }

    // MARK: Backfill (N3)

    private func queue(
        _ store: ProcessingStore, requeue: ProcessingRequeue, failures: ProcessingFailures, clock: TestClock,
        hooks: ProcessingQueue.Hooks = .init()
    ) -> ProcessingQueue {
        ProcessingQueue(
            container: store.container, deviceID: deviceA, failures: failures,
            stage: DocumentStage(recognizer: StubRecognizer()), requeue: requeue,
            watchdogSleep: ManualDebounce().sleep, now: clock.function, hooks: hooks)
    }

    /// A store with step 3's documents, re-queued by this device's pass: `old` had no thumbnail and is recorded.
    private func reQueued(_ store: ProcessingStore) throws -> (
        requeue: ProcessingRequeue, failures: ProcessingFailures, old: UUID
    ) {
        let failures = store.failures(deviceA)
        let requeue = ProcessingRequeue(defaultsSuite: failures.defaultsSuite)
        let old = try store.insert(
            stateRaw: "done", device: deviceB, claimedAt: processingStart.addingTimeInterval(-hour))
        requeue.run(in: store.container, deviceID: deviceA, now: processingStart)
        try #require(requeue.thumbnailBackfill == [old])
        return (requeue, failures, old)
    }

    @Test func aRecordedDocumentGetsAThumbnailFromProcessingAndLeavesTheRecord() async throws {
        let store = try ProcessingStore()
        defer { store.remove() }
        let clock = TestClock()
        let (requeue, failures, old) = try reQueued(store)

        let report = await queue(store, requeue: requeue, failures: failures, clock: clock).run()

        #expect(report.done == 1)
        #expect(report.thumbnailsBackfilled == 1)
        let document = try #require(try ProcessingStore.fetch(old, in: ModelContext(store.container)))
        let thumbnail = try #require(document.thumbnail)
        #expect(thumbnail.documentID == document.id)
        #expect(try max(Self.pixelSize(of: try #require(thumbnail.imageData)).height, 0) == 480)
        #expect(document.processingState == .done)
        #expect(requeue.thumbnailBackfill.isEmpty, "pruned after the result write")
        #expect(try Self.thumbnailCount(store.container) == 1)
        try Self.expectNoOrphanThumbnails(store.container)
    }

    /// N3: a document imported by this build whose thumbnail has not arrived (records arrive in any order) gets none
    /// from processing, so the arriving one never meets a second.
    @Test func aDocumentImportedByThisBuildWithoutItsThumbnailGetsNoneFromProcessing() async throws {
        let store = try ProcessingStore()
        defer { store.remove() }
        let clock = TestClock()
        let (requeue, failures, _) = try reQueued(store)
        let fresh = try store.insert(stateRaw: "pending", device: deviceA, claimedAt: processingStart)

        let report = await queue(store, requeue: requeue, failures: failures, clock: clock).run()

        #expect(report.done == 2)
        #expect(report.thumbnailsBackfilled == 1, "only the recorded one")
        #expect(try ProcessingStore.fetch(fresh, in: ModelContext(store.container))?.thumbnail == nil)
        #expect(try Self.thumbnailCount(store.container) == 1)
    }

    /// A recorded document whose thumbnail is linked before the result write (arrived by sync, or the other
    /// device's backfill) keeps it: no second one, no orphan. The record goes.
    @Test func aRecordedDocumentThatHasAThumbnailByNowGetsNoSecond() async throws {
        let store = try ProcessingStore()
        defer { store.remove() }
        let clock = TestClock()
        let (requeue, failures, old) = try reQueued(store)
        let arrived = try linkThumbnail(to: old, in: store)

        let report = await queue(store, requeue: requeue, failures: failures, clock: clock).run()

        #expect(report.done == 1)
        #expect(report.thumbnailsBackfilled == 0)
        #expect(try ProcessingStore.fetch(old, in: ModelContext(store.container))?.thumbnail?.instanceID == arrived)
        #expect(try Self.thumbnailCount(store.container) == 1)
        #expect(requeue.thumbnailBackfill.isEmpty)
        try Self.expectNoOrphanThumbnails(store.container)
    }

    /// A thumbnail linked by another save in the result write's window (after its fetch, before its check) makes the
    /// write back off: no insert. The next run completes with the one that arrived.
    @Test func aThumbnailLinkedInTheWindowMakesTheWriteBackOff() async throws {
        let store = try ProcessingStore()
        defer { store.remove() }
        let clock = TestClock()
        let (requeue, failures, old) = try reQueued(store)
        let linked = Mutex<UUID?>(nil)
        let hooks = ProcessingQueue.Hooks(beforeCheck: { write in
            guard write == .result, linked.withLock({ $0 }) == nil else { return }
            let id = try self.linkThumbnail(to: old, in: store)
            linked.withLock { $0 = id }
        })
        let processing = queue(store, requeue: requeue, failures: failures, clock: clock, hooks: hooks)

        let first = await processing.run()

        #expect(first.backedOff == 1)
        #expect(first.thumbnailsBackfilled == 0)
        #expect(try Self.thumbnailCount(store.container) == 1)
        #expect(requeue.thumbnailBackfill == [old], "kept until a result write saved")

        clock.advance(by: 60)
        let second = await processing.run()

        #expect(second.done == 1)
        #expect(second.thumbnailsBackfilled == 0)
        let arrived = try #require(linked.withLock { $0 })
        #expect(try ProcessingStore.fetch(old, in: ModelContext(store.container))?.thumbnail?.instanceID == arrived)
        #expect(try Self.thumbnailCount(store.container) == 1)
        #expect(requeue.thumbnailBackfill.isEmpty)
        try Self.expectNoOrphanThumbnails(store.container)
    }

    /// A recorded document the other device processed (`done`) or that is gone leaves the record at the next run.
    @Test func aRecordedDocumentSeenDoneOrGoneLeavesTheRecord() async throws {
        let store = try ProcessingStore()
        defer { store.remove() }
        let clock = TestClock()
        let failures = store.failures(deviceA)
        let requeue = ProcessingRequeue(defaultsSuite: failures.defaultsSuite)
        let done = try store.insert(stateRaw: "done")
        let gone = try store.insert(stateRaw: "done")
        let waiting = try store.insert(stateRaw: "done")
        requeue.run(in: store.container, deviceID: deviceA, now: processingStart)
        try #require(requeue.thumbnailBackfill == [done, gone, waiting])
        // The other device processed `done`; `gone` was deleted; `waiting` waits for its trash restore.
        try store.edit(done) { document, _ in document.processingState = .done }
        try store.edit(gone) { document, context in context.delete(document) }
        try store.edit(waiting) { document, _ in document.deletedAt = processingStart }

        _ = await queue(store, requeue: requeue, failures: failures, clock: clock).run()

        #expect(requeue.thumbnailBackfill == [waiting])
    }

    @discardableResult
    private func linkThumbnail(to id: UUID, in store: ProcessingStore) throws -> UUID {
        var instanceID: UUID?
        try store.edit(id) { document, context in
            let thumbnail = DocumentThumbnail(documentID: document.id, imageData: Data(count: 100))
            context.insert(thumbnail)
            document.thumbnail = thumbnail
            instanceID = thumbnail.instanceID
        }
        return try #require(instanceID)
    }
}
