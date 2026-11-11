#if os(iOS)
    import DokumentumCore
    import DokumentumKit
    import DokumentumTestSupport
    import Foundation
    import SwiftData
    import Synchronization
    import Testing

    @testable import Dokumentum

    /// The app's side of the share queue (plan of #4, part 4): import, removal only after a save or a duplicate,
    /// attempts and `Failed/`, the crash case, one run at a time, and the guard against the real app group.
    /// In-memory stores and a temporary queue folder per test; nothing touches the app group.
    @MainActor
    struct ShareQueueImporterTests {
        static let date = Date(timeIntervalSinceReferenceDate: 820_000_000)

        /// A queue in a new temporary folder (standing in for the group container), removed after `body`.
        private func withQueue(_ body: (ShareQueue) async throws -> Void) async throws {
            let container = FileManager.default.temporaryDirectory
                .appending(path: "ShareQueueImporterTests-\(UUID().uuidString)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: container) }
            let queue = try #require(ShareQueueImporter.queue(groupContainer: container, isIsolated: true))
            try await body(queue)
        }

        private func names(in folder: URL) -> [String] {
            ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
        }

        private func documents(in container: ModelContainer) throws -> [Document] {
            try ModelContext(container).fetch(FetchDescriptor<Document>(sortBy: [SortDescriptor(\.createdAt)]))
        }

        /// Runs `importer` once and waits for the run's end.
        @discardableResult
        private func runOnce(_ importer: ShareQueueImporter) async -> ImportReport? {
            let finished = TestSignal()
            let report = Mutex<ImportReport?>(nil)
            importer.didFinishRun = { finishedReport in
                report.withLock { $0 = finishedReport }
                finished.fire()
            }
            importer.requestRun()
            await finished.wait()
            importer.didFinishRun = nil
            return report.withLock { $0 }
        }

        @Test func anItemBecomesAnInboxDocumentAndIsRemoved() async throws {
            try await withQueue { queue in
                let container = try makeInMemoryContainer()
                let pdf = SyntheticPDF.make(pages: [["Stadtwerke"], ["Seite 2"]])
                try queue.add(data: pdf, originalFileName: "Stromrechnung.pdf", typeIdentifier: "com.adobe.pdf")
                let importer = ShareQueueImporter(
                    runner: ShareQueueRunner(
                        queue: queue, importer: DocumentImporter(container: container, deviceID: "DEVICE-A")))

                let report = try #require(await runOnce(importer))

                let document = try #require(try documents(in: container).first)
                #expect(try documents(in: container).count == 1)
                #expect(document.title == "Stromrechnung")
                #expect(document.originalFileName == "Stromrechnung.pdf")
                #expect(document.source == .file)
                #expect(document.isInbox)
                #expect(document.pageCount == 2)
                #expect(document.contentHash == ContentHash.sha256(pdf))
                #expect(document.file?.pdfData == pdf)
                #expect(report.imported == [document.instanceID])
                #expect(names(in: queue.itemsFolder).isEmpty, "the item is removed after the save")
                #expect(names(in: queue.failedFolder).isEmpty)
                #expect(importer.reports.isEmpty, "a run that imported everything shows no notice (PQ4)")
            }
        }

        @Test func anImageItemBecomesAnImageDocument() async throws {
            try await withQueue { queue in
                let container = try makeInMemoryContainer()
                let jpeg = SyntheticImage.makePortraitPhoto(lines: ["Kassenbon"])
                try queue.add(data: jpeg, originalFileName: "Kassenbon", typeIdentifier: "public.jpeg")
                let importer = ShareQueueImporter(
                    runner: ShareQueueRunner(
                        queue: queue, importer: DocumentImporter(container: container, deviceID: "DEVICE-A")))

                await runOnce(importer)

                let document = try #require(try documents(in: container).first)
                #expect(document.source == .image, "the item's type decides, not its name")
                #expect(document.title == "Kassenbon")
                #expect(document.contentHash == ContentHash.sha256(jpeg))
                #expect(names(in: queue.itemsFolder).isEmpty)
            }
        }

        @Test func aDuplicateItemIsRemovedAndNamedInTheNotice() async throws {
            try await withQueue { queue in
                let container = try makeInMemoryContainer()
                let documentImporter = DocumentImporter(container: container, deviceID: "DEVICE-A")
                let pdf = SyntheticPDF.make(pages: [["Gleich"]])
                let existing = await documentImporter.importFile(
                    data: pdf, fileName: "Stromrechnung.pdf", contentType: .pdf, source: .file)
                try queue.add(data: pdf, originalFileName: "Kopie.pdf", typeIdentifier: "com.adobe.pdf")
                let importer = ShareQueueImporter(runner: ShareQueueRunner(queue: queue, importer: documentImporter))

                let report = try #require(await runOnce(importer))

                #expect(try documents(in: container).count == 1, "no second document")
                guard case .imported(let id) = existing else {
                    Issue.record("the first import failed: \(existing)")
                    return
                }
                #expect(report.duplicates.map { $0.fileName } == ["Kopie.pdf"])
                #expect(report.duplicates.map { $0.existing } == [id])
                #expect(names(in: queue.itemsFolder).isEmpty, "a duplicate's item is removed")
                let notices = importer.takeReports().compactMap { $0.notice(.app) }
                #expect(notices.count == 1)
                #expect(notices.first?.message.contains("Kopie.pdf") == true)
                #expect(notices.first?.message.contains("Stromrechnung") == true)
                #expect(importer.reports.isEmpty, "handed over once")
            }
        }

        @Test func aFailingItemStaysWithOneMoreAttemptAndItsThirdFailureMovesItToFailed() async throws {
            try await withQueue { queue in
                let container = try makeInMemoryContainer()
                let id = try queue.add(
                    data: Data("not a PDF".utf8), originalFileName: "Kaputt.pdf", typeIdentifier: "com.adobe.pdf")
                let importer = ShareQueueImporter(
                    runner: ShareQueueRunner(
                        queue: queue, importer: DocumentImporter(container: container, deviceID: "DEVICE-A")))

                for attempt in 1..<ShareQueue.maxAttempts {
                    let report = try #require(await runOnce(importer))
                    #expect(report.entries.isEmpty, "a failure that is tried again is not reported yet")
                    let item = try #require(queue.scan().items.first)
                    #expect(item.id == id)
                    #expect(item.info.attempts == attempt, "one more attempt per run")
                    #expect(importer.reports.isEmpty)
                }
                let report = try #require(await runOnce(importer))

                #expect(report.failures.map { $0.fileName } == ["Kaputt.pdf"])
                #expect(report.failures.map { $0.failure } == [.unreadablePDF])
                #expect(names(in: queue.itemsFolder).isEmpty)
                #expect(names(in: queue.failedFolder) == [id.uuidString], "kept in Failed/ (PQ6)")
                #expect(try documents(in: container).isEmpty)
                let notices = importer.takeReports().compactMap { $0.notice(.app) }
                #expect(notices.count == 1 && notices.first?.message.contains("Kaputt.pdf") == true)

                let after = try #require(await runOnce(importer))
                #expect(after.entries.isEmpty, "named once")
                #expect(names(in: queue.failedFolder) == [id.uuidString], "nothing empties Failed/")
            }
        }

        @Test func anItemWithNoAttemptLeftMovesToFailedWithoutAnotherImport() async throws {
            try await withQueue { queue in
                let stub = StubImporter()
                let id = try queue.add(data: Data("x".utf8), originalFileName: "a.pdf", typeIdentifier: "com.adobe.pdf")
                // Three attempts that each ended in a crash: counted, never finished.
                var item = try #require(queue.scan().items.first)
                for _ in 0..<ShareQueue.maxAttempts { item = try queue.recordAttempt(item) }
                let importer = ShareQueueImporter(runner: ShareQueueRunner(queue: queue, importer: stub))

                let report = try #require(await runOnce(importer))

                #expect(stub.fileNames.isEmpty)
                #expect(report.failures.map { $0.fileName } == ["a.pdf"])
                #expect(names(in: queue.failedFolder) == [id.uuidString])
            }
        }

        /// A crash after the save and before the removal: the next run gives no second document and removes the
        /// item.
        @Test func theCrashCaseGivesNoSecondDocumentAndRemovesTheItem() async throws {
            try await withQueue { queue in
                let container = try makeInMemoryContainer()
                let documentImporter = DocumentImporter(container: container, deviceID: "DEVICE-A")
                let pdf = SyntheticPDF.make(pages: [["Absturz"]])
                try queue.add(data: pdf, originalFileName: "Vertrag.pdf", typeIdentifier: "com.adobe.pdf")
                let crashing = ShareQueueImporter(
                    runner: ShareQueueRunner(queue: queue, importer: documentImporter, shouldRemove: { _ in false }))

                await runOnce(crashing)

                #expect(try documents(in: container).count == 1, "the save is done")
                #expect(queue.scan().items.map(\.info.attempts) == [1], "the item is still there")

                let next = ShareQueueImporter(runner: ShareQueueRunner(queue: queue, importer: documentImporter))
                let report = try #require(await runOnce(next))

                let documents = try documents(in: container)
                #expect(documents.count == 1, "no second document")
                #expect(report.duplicates.map { $0.existing } == documents.map(\.instanceID))
                #expect(names(in: queue.itemsFolder).isEmpty, "removed as a duplicate")
                #expect(names(in: queue.failedFolder).isEmpty)
            }
        }

        /// Launch and `.active` at once, and another `.active`: one run plus exactly one queued run, one attempt
        /// per item and run, each item imported once.
        @Test func twoTriggersAtOnceGiveOneRunPlusOneQueuedRun() async throws {
            try await withQueue { queue in
                let imported = UUID()
                let stub = StubImporter(["a.pdf": .imported(instanceID: imported)])
                try queue.add(
                    data: Data("a".utf8), originalFileName: "a.pdf", typeIdentifier: "com.adobe.pdf",
                    createdAt: Self.date)
                let failing = try queue.add(
                    data: Data("b".utf8), originalFileName: "b.pdf", typeIdentifier: "com.adobe.pdf",
                    createdAt: Self.date.addingTimeInterval(1))
                let held = Checkpoint()
                defer { held.release() }
                let importer = ShareQueueImporter(
                    runner: ShareQueueRunner(
                        queue: queue, importer: stub,
                        willImport: { item in if item.fileName == "a.pdf" { await held.pass() } }))
                let finished = TestSignal()
                importer.didFinishRun = { _ in finished.fire() }

                importer.requestRun()  // launch
                importer.requestRun()  // .active
                await held.reached()
                importer.requestRun()  // another .active during the run
                #expect(importer.isQueued)
                held.release()
                await finished.wait(for: 2)

                #expect(importer.completedRuns == 2)
                #expect(!importer.isQueued)
                #expect(stub.fileNames == ["a.pdf", "b.pdf", "b.pdf"], "a once; b once per run")
                #expect(names(in: queue.itemsFolder) == [failing.uuidString])
                #expect(queue.scan().items.map(\.info.attempts) == [2], "one attempt per run, never two")
                #expect(names(in: queue.failedFolder).isEmpty)

                // The importer takes requests again afterwards.
                importer.requestRun()
                await finished.wait(for: 3)
                #expect(importer.completedRuns == 3)
            }
        }

        @Test func anItemRemovedMeanwhileIsNoError() async throws {
            try await withQueue { queue in
                let imported = UUID()
                let id = try queue.add(data: Data("a".utf8), originalFileName: "a.pdf", typeIdentifier: "com.adobe.pdf")
                let importer = ShareQueueImporter(
                    runner: ShareQueueRunner(
                        queue: queue, importer: StubImporter(["a.pdf": .imported(instanceID: imported)]),
                        shouldRemove: { item in
                            // Someone else removed it first.
                            (try? queue.remove(item.id)) == true
                        }))

                let report = try #require(await runOnce(importer))

                #expect(report.imported == [imported])
                #expect(names(in: queue.itemsFolder).isEmpty)
                #expect(names(in: queue.failedFolder).isEmpty)
                #expect(!FileManager.default.fileExists(atPath: queue.itemsFolder.appending(path: id.uuidString).path))
            }
        }

        /// Review B, B1: the attempt is on disk before the import starts, so a payload that crashes the importer
        /// uses up its attempts instead of looping at every launch.
        @Test func theAttemptIsWrittenBeforeTheImport() async throws {
            try await withQueue { queue in
                let stub = StubImporter(["a.pdf": .imported(instanceID: UUID())])
                try queue.add(data: Data("a".utf8), originalFileName: "a.pdf", typeIdentifier: "com.adobe.pdf")
                let held = Checkpoint()
                defer { held.release() }
                let importer = ShareQueueImporter(
                    runner: ShareQueueRunner(queue: queue, importer: stub, willImport: { _ in await held.pass() }))
                let finished = TestSignal()
                importer.didFinishRun = { _ in finished.fire() }

                importer.requestRun()
                await held.reached()

                #expect(queue.scan().items.map(\.info.attempts) == [1], "counted on disk before the import")
                #expect(stub.fileNames.isEmpty, "the import has not started")
                held.release()
                await finished.wait()
                #expect(stub.fileNames == ["a.pdf"])
            }
        }

        /// Review A, B1 (`aLinkedPayloadIsReadThroughTheLink`): a payload that is a symbolic link to a PDF outside
        /// the queue is never read; it fails like an unreadable file and ends in `Failed/`.
        @Test func aPayloadThatIsALinkIsNotFollowedOutOfTheQueue() async throws {
            try await withQueue { queue in
                let container = try makeInMemoryContainer()
                let outside = queue.root.deletingLastPathComponent().appending(path: "outside.pdf")
                try SyntheticPDF.make(pages: [["Ausserhalb"]]).write(to: outside)
                let id = try queue.add(
                    data: Data("%PDF".utf8), originalFileName: "lent.pdf", typeIdentifier: "com.adobe.pdf")
                var item = try #require(queue.scan().items.first)
                try FileManager.default.removeItem(at: queue.payloadURL(of: item))
                try FileManager.default.createSymbolicLink(at: queue.payloadURL(of: item), withDestinationURL: outside)
                // Two earlier attempts, so this run is its last.
                for _ in 1..<ShareQueue.maxAttempts { item = try queue.recordAttempt(item) }
                let importer = ShareQueueImporter(
                    runner: ShareQueueRunner(
                        queue: queue, importer: DocumentImporter(container: container, deviceID: "DEVICE-A")))

                let report = try #require(await runOnce(importer))

                #expect(try documents(in: container).isEmpty, "the file outside the queue is not imported")
                #expect(report.failures.map { $0.failure } == [.couldNotRead])
                #expect(names(in: queue.failedFolder) == [id.uuidString])
                #expect(FileManager.default.fileExists(atPath: outside.path))
            }
        }

        /// Review B, N1: a `-UITestLocalStore` launch leaves the real queue alone too.
        @Test func aUITestLaunchWithALocalStoreIsIsolatedForTheQueue() {
            #expect(ShareQueueImporter.isIsolatedLaunch(isIsolated: false, arguments: ["-UITestLocalStore", "probe"]))
            #expect(ShareQueueImporter.isIsolatedLaunch(isIsolated: true, arguments: []))
            #expect(!ShareQueueImporter.isIsolatedLaunch(isIsolated: false, arguments: ["-AppleLanguages", "(de)"]))
        }

        @Test func withoutAGroupContainerNothingRuns() {
            #expect(ShareQueueImporter.queue(groupContainer: nil, isIsolated: false) == nil)
            #expect(ShareQueueImporter.queue(groupContainer: nil, isIsolated: true) == nil)
        }

        @Test func anIsolatedRunRefusesTheAppGroup() {
            let group = URL(
                filePath: "/Users/x/Library/Developer/CoreSimulator/Devices/D/data/Containers/Shared/AppGroup/G/",
                directoryHint: .isDirectory)
            #expect(ShareQueueImporter.queue(groupContainer: group, isIsolated: true) == nil)
            #expect(
                ShareQueueImporter.queue(groupContainer: group, isIsolated: false)?.root.path.hasSuffix(
                    "AppGroup/G/ShareQueue") == true, "the app outside tests uses its group")
            let temporary = FileManager.default.temporaryDirectory
            #expect(ShareQueueImporter.queue(groupContainer: temporary, isIsolated: true) != nil)
        }

        @Test func thisTestRunHasNoShareQueueImporter() throws {
            let container = try makeInMemoryContainer()
            #expect(TestEnvironment.isIsolated)
            #expect(
                ShareQueueImporter.forApp(importer: DocumentImporter(container: container, deviceID: "DEVICE-A"))
                    == nil, "the app host never imports the real queue")
        }

        @Test func aShareQueueReportBecomesANoticeWithoutASelection() throws {
            let library = LibraryModel(source: StoreLibrarySource(container: try makeInMemoryContainer()))
            library.selection = .all
            let controller = ImportController(importer: StubImporter(), reader: StubReader(), library: library)
            let existing = UUID()
            var duplicate = ImportReport()
            duplicate.add(fileName: "Kopie.pdf", outcome: .duplicate(of: existing, title: "Rechnung", isTrashed: false))
            var single = ImportReport()
            single.add(fileName: "Neu.pdf", outcome: .imported(instanceID: UUID()))

            controller.showShareQueueReports([single, duplicate])

            #expect(controller.notices.shown?.message.contains("Kopie.pdf") == true)
            #expect(controller.notices.waiting.isEmpty, "a report without a notice adds none")
            #expect(library.selection == .all, "nothing is selected (PQ12)")
            #expect(library.selectedDocumentID == nil)
        }
    }
#endif
