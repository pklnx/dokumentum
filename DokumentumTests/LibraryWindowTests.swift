import DokumentumCore
import DokumentumKit
import DokumentumTestSupport
import Foundation
import PDFKit
import Testing

@testable import Dokumentum

/// A source whose reads are counted and whose loads answer in the order the test releases them.
@MainActor
private final class ScriptedSource: LibrarySource {
    let reads = TestSignal()
    let changes = AsyncStream<Void> { _ in }
    /// One answer per `loadPDF` call, in call order; each waits at its checkpoint, if it has one.
    nonisolated let answers: [(gate: Checkpoint?, state: PDFLoadState)]
    nonisolated let calls = TestSignal()

    init(answers: [(gate: Checkpoint?, state: PDFLoadState)] = []) {
        self.answers = answers
    }

    func snapshot() -> LibrarySnapshot {
        reads.fire()
        return FixtureCatalog.snapshot
    }

    nonisolated func loadPDF(instanceID: UUID) async -> PDFLoadState {
        let index = calls.count
        calls.fire()
        guard index < answers.count else { return .noDocument }
        await answers[index].gate?.pass()
        return answers[index].state
    }
}

/// The library window's wiring: what it reads when, which load wins, and what the store of the launch
/// decides for the footer and the debug command.
@MainActor
struct LibraryWindowTests {
    /// SwiftUI creates the root view again on every evaluation of the app's body and keeps only the first
    /// model, so creating it must not read the library; the window reads it when it appears.
    @Test func creatingTheRootViewReadsNothing() {
        let source = ScriptedSource()
        _ = LibraryRootView(source: source, launchStore: LaunchStore(choice: .local, opened: .local))
        #expect(source.reads.count == 0)

        let model = LibraryModel(source: source, loadNow: false)
        #expect(source.reads.count == 0)
        model.loadIfNeeded()
        model.loadIfNeeded()
        #expect(source.reads.count == 1)
        #expect(model.counts.count(for: .inbox) == 5)
    }

    /// An older load of the same document that finishes last (it read before the file arrived) does not
    /// replace the newer one's PDF.
    @Test func anOlderLoadThatFinishesLastIsDropped() async {
        let id = FixtureCatalog.documentID(1)
        let olderGate = Checkpoint()
        defer { olderGate.release() }
        let pdf = SyntheticPDF.make(pages: [["Stadtwerke", "Strom"]])
        let source = ScriptedSource(answers: [(olderGate, .noFile), (nil, .data(pdf))])
        let model = LibraryModel(source: source)
        model.selectedDocumentID = id

        let older = TestSignal()
        Task {
            await model.loadDetail(for: id)
            older.fire()
        }
        await olderGate.reached()
        await model.loadDetail(for: id)
        #expect(model.detail == .pdf(instanceID: id, data: pdf))
        olderGate.release()
        await older.wait()
        #expect(model.detail == .pdf(instanceID: id, data: pdf))
    }

    /// The debug command asks first for every store on disk; the window takes that from its `LaunchStore`.
    @Test(arguments: [
        (StoreChoice.cloudKit, ArchiveStore.OpenedStore.cloudKit, true),
        (.cloudKit, .local, true),
        (.local, .local, true),
        (.inMemory(seed: false), .inMemory, false),
    ])
    func theWindowsSampleCommandAsksForStoresOnDisk(
        choice: StoreChoice, opened: ArchiveStore.OpenedStore, asks: Bool
    ) {
        let view = LibraryRootView(source: ScriptedSource(), launchStore: LaunchStore(choice: choice, opened: opened))
        #expect(view.sampleDocumentsCommand.asksFirst == asks)
    }

    /// Each reason has its own words, in English and German.
    @Test func eachSyncOffReasonHasItsText() {
        let expected: [StoreSyncOffReason: (String, String)] = [
            .noICloudAccess: ("this build has no iCloud access", "dieser Build hat keinen iCloud-Zugriff"),
            .sampleData: ("sample data, not saved", "Beispieldaten, nicht gespeichert"),
            .cloudKitStoreFailed: (
                "the iCloud store could not be opened", "der iCloud-Speicher konnte nicht geöffnet werden"
            ),
            .archiveFailed: ("the archive could not be opened", "das Archiv konnte nicht geöffnet werden"),
        ]
        #expect(Set(expected.keys) == Set(StoreSyncOffReason.allCases))
        for (reason, (english, german)) in expected {
            var resource = SyncOffLine.reasonText(reason)
            #expect(resource.key == english, "\(reason)")
            resource.locale = Locale(identifier: "de")
            #expect(String(localized: resource) == german, "\(reason)")
        }
    }

    /// `-UITestLocalStore <name>` names a folder in the temporary directory and nothing else.
    @Test func theUITestLocalStoreStaysInTheTemporaryDirectory() {
        let temporary = URL(filePath: "/tmp/Probe", directoryHint: .isDirectory)
        #expect(
            UITestLocalStore.folder(arguments: ["-UITestLocalStore", "Launch-1"], temporaryDirectory: temporary)
                == temporary.appending(path: "DokumentumUITest-Launch-1", directoryHint: .isDirectory))
        for name in ["", "../Library", "a/b", "~", ".", "x y", "Ä", String(repeating: "a", count: 65)] {
            #expect(
                UITestLocalStore.folder(arguments: ["-UITestLocalStore", name], temporaryDirectory: temporary) == nil,
                "\(name)")
        }
        #expect(UITestLocalStore.folder(arguments: ["-UITestLocalStore"], temporaryDirectory: temporary) == nil)
        #expect(UITestLocalStore.folder(arguments: ["-UITestSeed", "YES"], temporaryDirectory: temporary) == nil)
    }
}
