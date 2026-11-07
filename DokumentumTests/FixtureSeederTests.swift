import DokumentumCore
import DokumentumKit
import DokumentumTestSupport
import Foundation
import PDFKit
import SwiftData
import Testing

@testable import Dokumentum

/// The sample documents on the store (plan of #3, part 2): the `-UITestSeed` store and the debug command
/// "Add Sample Documents". In-memory stores only.
/// A fresh in-memory store, kept alive until the end of the run: a context whose container is gone traps.
@MainActor
func makeInMemoryContainer() throws -> ModelContainer {
    let container = try ArchiveStore.open(ArchiveStore.configuration(for: .inMemory(seed: false)))
    keptContainers.append(container)
    return container
}

@MainActor private var keptContainers: [ModelContainer] = []

@MainActor
struct FixtureSeederTests {
    private func makeContainer() throws -> ModelContainer { try makeInMemoryContainer() }

    private func count<T: PersistentModel>(_ type: T.Type, in context: ModelContext) throws -> Int {
        try context.fetchCount(FetchDescriptor<T>())
    }

    /// Every `instanceID` of every entity the seeder wrote.
    private func instanceIDs(in context: ModelContext) throws -> [UUID] {
        try context.fetch(FetchDescriptor<Document>()).map(\.instanceID)
            + context.fetch(FetchDescriptor<DocumentFile>()).map(\.instanceID)
            + context.fetch(FetchDescriptor<DocumentText>()).map(\.instanceID)
            + context.fetch(FetchDescriptor<DokumentumCore.Tag>()).map(\.instanceID)
            + context.fetch(FetchDescriptor<Correspondent>()).map(\.instanceID)
            + context.fetch(FetchDescriptor<DocumentType>()).map(\.instanceID)
    }

    @Test func theCommandTwiceAddsNothingTheSecondTime() throws {
        let context = try makeContainer().mainContext
        let samples = FixtureCatalog.samples.count
        #expect(try FixtureSeeder.addSampleDocuments(to: context) == samples)
        let counts = try [
            count(Document.self, in: context), count(DocumentFile.self, in: context),
            count(DocumentText.self, in: context), count(DokumentumCore.Tag.self, in: context),
            count(Correspondent.self, in: context), count(DocumentType.self, in: context),
        ]
        #expect(counts == [samples, samples - 1, samples, 4, 3, 2])

        #expect(try FixtureSeeder.addSampleDocuments(to: context) == 0)
        let again = try [
            count(Document.self, in: context), count(DocumentFile.self, in: context),
            count(DocumentText.self, in: context), count(DokumentumCore.Tag.self, in: context),
            count(Correspondent.self, in: context), count(DocumentType.self, in: context),
        ]
        #expect(again == counts)
    }

    /// #2's rule: an `instanceID` is never copied. The fixed `5EED…` values are only the `id`.
    @Test func everyRecordOfTheCommandHasAFreshInstanceID() throws {
        let context = try makeContainer().mainContext
        let now = Date(timeIntervalSinceReferenceDate: 815_000_000)
        try FixtureSeeder.addSampleDocuments(to: context, now: now)
        let ids = try instanceIDs(in: context)
        #expect(Set(ids).count == ids.count)
        let fixed = Set(FixtureCatalog.samples.map(\.document.instanceID))
            .union(FixtureCatalog.tags.map(\.instanceID)).union(FixtureCatalog.correspondents.map(\.instanceID))
            .union(FixtureCatalog.documentTypes.map(\.instanceID))
        #expect(Set(ids).isDisjoint(with: fixed))
        for document in try context.fetch(FetchDescriptor<Document>()) {
            #expect(fixed.contains(document.id))
            #expect(document.instanceID != document.id)
            #expect(document.createdAt == now)
        }
        for tag in try context.fetch(FetchDescriptor<DokumentumCore.Tag>()) {
            #expect(tag.instanceID != tag.id)
            #expect(tag.createdAt == now)
        }
    }

    /// The `-UITestSeed` store keeps the fixed `instanceID`s, so UI tests can address each row.
    @Test func theUITestSeedKeepsTheFixedInstanceIDs() throws {
        let context = try makeContainer().mainContext
        FixtureSeeder.seedForUITests(context)
        let documents = try context.fetch(FetchDescriptor<Document>())
        #expect(Set(documents.map(\.instanceID)) == Set(FixtureCatalog.samples.map(\.document.instanceID)))
        #expect(documents.allSatisfy { $0.instanceID == $0.id })
        let snapshot = try StoreLibrarySource.read(in: context)
        #expect(Set(snapshot.tags) == Set(FixtureCatalog.tags))
        #expect(
            Set(snapshot.documents.map(\.instanceID)) == Set(FixtureCatalog.snapshot.documents.map(\.instanceID)))
    }

    /// Metadata is reused by normalized name, tags by parent plus normalized name; tombstones are never reused.
    @Test func theCommandReusesLiveMetadataByItsMergeKey() throws {
        let context = try makeContainer().mainContext
        let stadtwerke = Correspondent(name: "  STADTWERKE musterstadt ")
        let invoice = DocumentType(name: "invoice")
        let tombstone = Correspondent(name: "Musterbank AG")
        tombstone.mergedIntoID = UUID()
        // A top-level Golf is not "Auto › Golf".
        let topLevelGolf = DokumentumCore.Tag(name: "Golf")
        let auto = DokumentumCore.Tag(name: "AUTO")
        for record in [stadtwerke, tombstone] { context.insert(record) }
        context.insert(invoice)
        context.insert(topLevelGolf)
        context.insert(auto)
        try context.save()

        try FixtureSeeder.addSampleDocuments(to: context)
        let correspondents = try context.fetch(FetchDescriptor<Correspondent>())
        #expect(correspondents.count { MetadataName.normalized($0.name) == "stadtwerke musterstadt" } == 1)
        #expect(correspondents.count { MetadataName.normalized($0.name) == "musterbank ag" } == 2)
        #expect(try context.fetch(FetchDescriptor<DocumentType>()).count { $0.name.lowercased() == "invoice" } == 1)
        let tags = try context.fetch(FetchDescriptor<DokumentumCore.Tag>())
        #expect(tags.count { $0.name.lowercased() == "auto" } == 1)
        let golfs = tags.filter { $0.name == "Golf" }
        #expect(golfs.count == 2)
        #expect(golfs.contains { $0.parent?.instanceID == auto.instanceID })
        #expect(topLevelGolf.parent == nil)
        let bill = try #require(
            try context.fetch(FetchDescriptor<Document>()).first { $0.title == "Electricity bill October" })
        #expect(bill.correspondent?.instanceID == stadtwerke.instanceID)
        #expect(bill.documentType?.instanceID == invoice.instanceID)
    }

    /// Small synthetic data only: texts of at most 1 KB, and every file is the generated sample's bytes.
    @Test func theSeederWritesOnlySmallTextsAndGeneratedFiles() throws {
        let context = try makeContainer().mainContext
        try FixtureSeeder.addSampleDocuments(to: context)
        for document in try context.fetch(FetchDescriptor<Document>()) {
            let text = try #require(document.text, "every document gets its text in the same save")
            #expect(text.extractedText.utf8.count <= FixtureSeeder.textLimit)
            #expect(text.documentID == document.id)
            let sample = try #require(FixtureCatalog.samples.first { $0.document.instanceID == document.id })
            switch sample.file {
            case .missing:
                #expect(document.file == nil)
            case .notPDF:
                #expect(document.file?.pdfData == FixtureCatalog.notPDFData)
            case .pdf(let pages):
                let data = try #require(document.file?.pdfData)
                let pdf = try #require(PDFDocument(data: data))
                #expect(pdf.pageCount == pages.count)
                #expect(pdf.string?.contains("Sample document, generated for Dokumentum.") == true)
                #expect(document.pageCount == pages.count)
                #expect(document.fileSize == data.count)
            }
        }
        #expect(FixtureSeeder.text(of: FixtureCatalog.samples[0]).contains("Electricity bill October"))
    }
}

/// `LibraryModel` on the store: the debug command and a file that arrives later reach the views through
/// the change events, without polling.
@MainActor
struct StoreLibraryModelTests {
    @Test func aFileInsertedLaterFlipsTheDetailState() async throws {
        let container = try makeInMemoryContainer()
        let document = Document(title: "Strom")
        container.mainContext.insert(document)
        try container.mainContext.save()
        let model = LibraryModel(source: StoreLibrarySource(container: container))
        model.selectedDocumentID = document.instanceID
        await model.loadDetail(for: document.instanceID)
        #expect(model.detail == .stillDownloading)

        let observer = Task { await model.observeChanges() }
        defer { observer.cancel() }
        let shown = TestSignal()
        let watcher = Task { @MainActor in
            for await detail in Observations({ model.detail }) {
                if case .pdf = detail {
                    shown.fire()
                    return
                }
            }
        }
        defer { watcher.cancel() }
        let file = DocumentFile(
            documentID: document.id, pdfData: SyntheticPDF.make(pages: [["Stadtwerke", "Strom"]]))
        container.mainContext.insert(file)
        document.file = file
        try container.mainContext.save()
        await shown.wait()
        guard case .pdf(let instanceID, _) = model.detail else {
            Issue.record("No PDF: \(model.detail)")
            return
        }
        #expect(instanceID == document.instanceID)
    }

    @Test func theCommandFillsTheInbox() async throws {
        let container = try makeInMemoryContainer()
        let source = StoreLibrarySource(container: container)
        let model = LibraryModel(source: source)
        #expect(model.counts.count(for: .all) == 0)
        let observer = Task { await model.observeChanges() }
        defer { observer.cancel() }
        let filled = TestSignal()
        let watcher = Task { @MainActor in
            for await count in Observations({ model.counts.count(for: .inbox) }) where count > 0 {
                filled.fire()
                return
            }
        }
        defer { watcher.cancel() }
        try FixtureSeeder.addSampleDocuments(to: container.mainContext)
        await filled.wait()
        #expect(model.counts.count(for: .inbox) == FixtureCatalog.samples.count { $0.document.isInbox })
        #expect(model.counts.count(for: .all) == FixtureCatalog.samples.count)
    }

    @Test func aTagThatEndsNowhereShowsByNameOnTheRow() throws {
        let container = try makeInMemoryContainer()
        let context = container.mainContext
        let lost = DokumentumCore.Tag(name: "Steuer")
        lost.mergedIntoID = UUID()
        let live = DokumentumCore.Tag(name: "Haus")
        context.insert(lost)
        context.insert(live)
        let document = Document(title: "Strom")
        context.insert(document)
        document.tags = [lost, live]
        try context.save()
        let model = LibraryModel(source: StoreLibrarySource(container: container))
        let row = try #require(model.documents.first)
        #expect(model.tagPaths(of: row) == ["Haus", "Steuer"])
        #expect(model.tree.roots == [live.instanceID])
    }
}
