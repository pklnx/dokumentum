import DokumentumKit
import DokumentumTestSupport
import Foundation
import Testing

@testable import Dokumentum

/// A source the test controls: it counts its reads with a signal, fires `changes` on demand, and can
/// hold a PDF load at a checkpoint.
@MainActor
private final class StubSource: LibrarySource {
    var current: LibrarySnapshot
    let reads = TestSignal()
    let changes: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation
    nonisolated let files: [UUID: PDFLoadState]
    nonisolated let loadGate: Checkpoint?

    init(_ snapshot: LibrarySnapshot, files: [UUID: PDFLoadState] = [:], loadGate: Checkpoint? = nil) {
        current = snapshot
        self.files = files
        self.loadGate = loadGate
        (changes, continuation) = AsyncStream.makeStream()
    }

    func snapshot() -> LibrarySnapshot {
        reads.fire()
        return current
    }

    func change() { continuation.yield() }

    nonisolated func loadPDF(instanceID: UUID) async -> PDFLoadState {
        await loadGate?.pass()
        return files[instanceID] ?? .noDocument
    }
}

@MainActor
struct LibraryModelTests {
    private typealias Fixtures = FixtureCatalog

    private func ids(_ documents: [LibraryDocument]) -> [UUID] { documents.map(\.instanceID) }

    @Test func itStartsOnTheInbox() {
        let model = LibraryModel(source: FixtureLibrarySource())
        #expect(model.selection == .inbox)
        #expect(ids(model.documents) == [1, 2, 5, 6, 9].map(Fixtures.documentID))
        #expect(model.counts.count(for: .inbox) == 5)
        #expect(model.counts.count(for: .all) == 9)
    }

    @Test func theSelectionChangesTheList() {
        let model = LibraryModel(source: FixtureLibrarySource())
        model.selection = .tag(Fixtures.tax.instanceID)
        #expect(ids(model.documents) == [1, 2, 3].map(Fixtures.documentID))
        model.selection = .tag(Fixtures.auto.instanceID)
        #expect(ids(model.documents) == [7, 8].map(Fixtures.documentID))
        model.selection = .correspondent(Fixtures.stadtwerke.instanceID)
        #expect(ids(model.documents) == [1, 3].map(Fixtures.documentID))
        model.selection = .documentType(Fixtures.letter.instanceID)
        #expect(ids(model.documents) == [4, 5, 6, 7].map(Fixtures.documentID))
        model.selection = .all
        #expect(model.documents.count == 9)
        model.selection = nil
        #expect(model.documents.isEmpty)
    }

    @Test func aDocumentThatLeavesTheListIsDeselected() {
        let model = LibraryModel(source: FixtureLibrarySource())
        model.selection = .all
        model.selectedDocumentID = Fixtures.documentID(7)
        model.selection = .tag(Fixtures.auto.instanceID)
        #expect(model.selectedDocumentID == Fixtures.documentID(7))
        model.selection = .inbox
        #expect(model.selectedDocumentID == nil)
    }

    @Test func aChangesEventReadsTheSourceAgain() async {
        let source = StubSource(Fixtures.snapshot)
        let model = LibraryModel(source: source)
        #expect(source.reads.count == 1)
        let observer = Task { await model.observeChanges() }
        defer { observer.cancel() }

        var changed = Fixtures.snapshot
        changed.documents.removeAll { $0.instanceID == Fixtures.documentID(1) }
        source.current = changed
        source.change()
        await source.reads.wait(for: 2)
        #expect(ids(model.documents) == [2, 5, 6, 9].map(Fixtures.documentID))
        #expect(model.counts.count(for: .tag(Fixtures.tax.instanceID)) == 2)
    }

    @Test func aChangesEventReloadsTheOpenDocument() async {
        let id = Fixtures.documentID(1)
        let gate = Checkpoint()
        defer { gate.release() }
        let source = StubSource(Fixtures.snapshot, files: [id: .noFile], loadGate: gate)
        let model = LibraryModel(source: source)
        model.selectedDocumentID = id
        let observer = Task { await model.observeChanges() }
        defer { observer.cancel() }

        let downloading = detailSignal(model, .stillDownloading)
        defer { downloading.watcher.cancel() }
        source.change()
        await gate.reached()
        gate.release()
        await downloading.signal.wait()
        #expect(model.detail == .stillDownloading)
    }

    /// Fires once `model.detail` becomes `expected`.
    private func detailSignal(_ model: LibraryModel, _ expected: DetailState) -> (
        signal: TestSignal, watcher: Task<Void, Never>
    ) {
        let signal = TestSignal()
        let watcher = Task { @MainActor in
            for await detail in Observations({ model.detail }) where detail == expected {
                signal.fire()
                return
            }
        }
        return (signal, watcher)
    }

    @Test func theDetailShowsEachFixtureCase() async {
        let model = LibraryModel(source: FixtureLibrarySource())
        model.selection = .all

        await model.loadDetail(for: nil)
        #expect(model.detail == .noSelection)

        let pdf = Fixtures.documentID(4)
        model.selectedDocumentID = pdf
        await model.loadDetail(for: pdf)
        guard case .pdf(let shown, let data) = model.detail else {
            Issue.record("No PDF: \(model.detail)")
            return
        }
        #expect(shown == pdf)
        #expect(await LibraryModel.isReadablePDF(data))

        let missing = Fixtures.documentID(3)
        model.selectedDocumentID = missing
        await model.loadDetail(for: missing)
        #expect(model.detail == .stillDownloading)

        let notPDF = Fixtures.documentID(9)
        model.selectedDocumentID = notPDF
        await model.loadDetail(for: notPDF)
        #expect(model.detail == .unreadable)

        let unknown = Fixtures.documentID(99)
        model.selectedDocumentID = unknown
        await model.loadDetail(for: unknown)
        #expect(model.detail == .noSelection)
    }

    @Test func aFileWithoutDataIsStillDownloading() async {
        let id = Fixtures.documentID(1)
        let model = LibraryModel(source: StubSource(Fixtures.snapshot, files: [id: .noData]))
        model.selectedDocumentID = id
        await model.loadDetail(for: id)
        #expect(model.detail == .stillDownloading)
    }

    @Test func aLoadThatArrivesAfterTheSelectionMovedOnIsDropped() async {
        let first = Fixtures.documentID(1)
        let second = Fixtures.documentID(2)
        let gate = Checkpoint()
        defer { gate.release() }
        let source = StubSource(Fixtures.snapshot, files: [first: .noFile], loadGate: gate)
        let model = LibraryModel(source: source)
        model.selectedDocumentID = first
        let finished = TestSignal()
        Task {
            await model.loadDetail(for: first)
            finished.fire()
        }
        await gate.reached()
        #expect(model.detail == .loading)
        model.selectedDocumentID = second
        gate.release()
        await finished.wait()
        #expect(model.detail == .loading)
    }

    @Test func theFixturesCoverEverySpecialCase() {
        let documents = Fixtures.samples.map(\.document)
        #expect(Set(documents.map(\.instanceID)).count == documents.count)
        #expect(Fixtures.samples.filter { $0.file == .missing }.count == 1)
        #expect(Fixtures.samples.filter { $0.file == .notPDF }.count == 1)
        #expect(documents.contains { $0.title.isEmpty })
        #expect(documents.contains { $0.title.count > 80 })
        #expect(Fixtures.samples.contains { if case .pdf(let pages) = $0.file { pages.count == 3 } else { false } })
        #expect(documents.contains { $0.isInbox } && documents.contains { !$0.isInbox })
        #expect(Fixtures.samples.allSatisfy { ($0.file == .missing) == ($0.document.fileState == .missing) })
        let tree = TagTree(Fixtures.tags)
        #expect(tree.displayPath(of: Fixtures.golf.instanceID) == "Auto › Golf")
    }
}
