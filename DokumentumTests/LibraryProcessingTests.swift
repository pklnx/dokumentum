import DokumentumCore
import DokumentumKit
import DokumentumTestSupport
import Foundation
import SwiftData
import Testing

@testable import Dokumentum

/// Thumbnails and the processing state in the library (#6, part 4): the samples carry thumbnails and states as the
/// importer and the queue leave them, the store's rows carry the state, a row's thumbnail is loaded by the source, and
/// "Try again" goes through the queue and shows at once.
@MainActor
struct LibraryProcessingTests {
    /// A failure counter in a defaults suite of its own, removed by the caller.
    private func failures() -> (ProcessingFailures, suite: String) {
        let suite = "DokumentumTests-LibraryProcessing-\(UUID().uuidString)"
        return (ProcessingFailures(defaultsSuite: suite), suite)
    }

    @Test func theSamplesHaveThumbnailsOfTheirPDFsAndTheCatalogsStates() throws {
        let context = try makeInMemoryContainer().mainContext
        try FixtureSeeder.addSampleDocuments(to: context)
        for document in try context.fetch(FetchDescriptor<Document>()) {
            let sample = try #require(FixtureCatalog.samples.first { $0.document.instanceID == document.id })
            if case .pdf = sample.file {
                #expect(document.thumbnail?.documentID == document.id, "\(sample.document.title)")
                #expect(document.thumbnail?.imageData?.isEmpty == false)
            } else {
                #expect(document.thumbnail == nil, "\(sample.document.title)")
            }
            #expect(document.processingState == sample.document.processingState)
        }
        #expect(
            FixtureCatalog.samples.filter { $0.document.processingState == .failed }.map(\.document.instanceID)
                == [FixtureCatalog.documentID(6), FixtureCatalog.documentID(9)])
        #expect(
            FixtureCatalog.samples.first { $0.document.processingState == .pending }?.document.title
                == "Medical invoice")
    }

    @Test func theStoresRowsCarryTheStateAndTheSourceLoadsTheirThumbnails() async throws {
        let container = try makeInMemoryContainer()
        FixtureSeeder.seedForUITests(container.mainContext)
        let source = StoreLibrarySource(container: container)
        let rows = source.snapshot().documents
        let receipt = FixtureCatalog.documentID(9)
        let bill = FixtureCatalog.documentID(1)
        #expect(rows.first { $0.instanceID == receipt }?.processingState == .failed)
        #expect(rows.first { $0.instanceID == bill }?.processingState == .done)

        let image = try #require(await source.loadThumbnail(instanceID: bill))
        #expect(image.height == ThumbnailLoader.pixelSize)
        #expect(await source.loadThumbnail(instanceID: receipt) == nil, "not a PDF: no thumbnail")
    }

    /// "Try again" through a queue on the store: the document is `pending` with this device's claim, the model shows
    /// it at once (it reads the library again), and the counter is gone.
    @Test func tryAgainSetsAFailedDocumentBackToPendingAndShowsIt() async throws {
        let container = try makeInMemoryContainer()
        FixtureSeeder.seedForUITests(container.mainContext)
        let (counter, suite) = failures()
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let receipt = FixtureCatalog.documentID(9)
        counter.fail(counter.begin(receipt, at: Date()))
        let queue = ProcessingQueue(container: container, deviceID: "DEVICE-A", failures: counter)
        let model = LibraryModel(source: StoreLibrarySource(container: container), retrier: queue)
        model.selectedDocumentID = receipt
        #expect(model.canRetryProcessing)
        #expect(model.selectedDocument?.processingState == .failed)
        let revision = model.revision

        let outcome = await model.retryProcessing(of: receipt)

        #expect(outcome == .queued)
        #expect(model.selectedDocument?.processingState == .pending)
        #expect(model.revision > revision, "the library was read again")
        #expect(model.retrying == nil)
        #expect(counter.count(for: receipt) == 0)
        let stored = try #require(
            try ModelContext(container).fetch(
                FetchDescriptor<Document>(predicate: #Predicate { $0.instanceID == receipt })
            )
            .first)
        #expect(stored.processingDeviceID == "DEVICE-A")
    }

    @Test func withoutARetrierThereIsNoTryAgain() async {
        let model = LibraryModel(source: FixtureLibrarySource())
        #expect(!model.canRetryProcessing)
        #expect(await model.retryProcessing(of: FixtureCatalog.documentID(9)) == nil)
    }

    /// The status line's states: a line for pending, processing and failed; none for done and a newer build's state.
    @Test func theStatusLineShowsOnlyTheOpenStates() {
        #expect(ProcessingStatusBar.Status(.pending) == .pending)
        #expect(ProcessingStatusBar.Status(.processing) == .processing)
        #expect(ProcessingStatusBar.Status(.failed) == .failed)
        #expect(ProcessingStatusBar.Status(.done) == nil)
        #expect(ProcessingStatusBar.Status(.unknown) == nil)
    }
}
