import DokumentumCore
import DokumentumKit
import DokumentumTestSupport
import Foundation
import PDFKit
import SwiftData
import Testing

@testable import Dokumentum

/// The Sync lab's documents and its direct writes (plan of #31, Approach 3, T8, Revision 1 note 2): lab documents come
/// through the real importer in one save; the direct writes act on lab documents and lab tags only. In-memory stores.
@MainActor
struct SyncLabGeneratorTests {
    private let deviceID = "LAB-DEVICE"

    /// Counts the saves of `container`'s contexts while it lives.
    final class SaveCounter {
        let saves = TestSignal()
        private var token: (any NSObjectProtocol)?

        init(_ container: ModelContainer) {
            let observed = ObjectIdentifier(container)
            let saves = saves
            token = NotificationCenter.default.addObserver(forName: ModelContext.didSave, object: nil, queue: nil) {
                notification in
                guard let context = notification.object as? ModelContext,
                    ObjectIdentifier(context.container) == observed
                else { return }
                saves.fire()
            }
        }

        func stop() {
            if let token { NotificationCenter.default.removeObserver(token) }
            token = nil
        }
    }

    private func document(_ instanceID: UUID, in container: ModelContainer) throws -> Document {
        let context = ModelContext(container)
        return try #require(
            try context.fetch(FetchDescriptor<Document>(predicate: #Predicate { $0.instanceID == instanceID })).first)
    }

    // MARK: Generated documents

    /// A text document comes through the importer: the claim of this device, the file, the thumbnail and the empty
    /// text record in one save, and the lab prefix on its file name.
    @Test func aTextDocumentImportsInOneSaveWithClaimFileAndText() async throws {
        let container = try makeInMemoryContainer()
        let importer = DocumentImporter(container: container, deviceID: deviceID)
        let counter = SaveCounter(container)
        defer { counter.stop() }

        let word = SyncLabGenerator.uniqueWord()
        let outcome = await SyncLabGenerator.importText(word: word, pages: 3, importer: importer)
        guard case .imported(let instanceID) = outcome else {
            Issue.record("not imported: \(outcome)")
            return
        }
        #expect(counter.saves.count == 1, "the import took more than one save")
        let document = try document(instanceID, in: container)
        #expect(document.processingDeviceID == deviceID)
        #expect(document.processingState == .pending)
        #expect(document.processingClaimedAt != nil)
        #expect(document.file?.pdfData != nil)
        #expect(document.text?.extractedText == "")
        #expect(document.thumbnail != nil)
        #expect(document.pageCount == 3)
        #expect(document.originalFileName == "SyncLab-text-\(word).pdf")
        #expect(SyncLabActions.isLabDocument(originalFileName: document.originalFileName))
        let data = try #require(document.file?.pdfData)
        let pdf = try #require(PDFDocument(data: data))
        #expect(pdf.string?.contains(word) == true)
    }

    /// Two generated documents never share a hash, so the importer's duplicate check never matches; the unique word
    /// is `syncw` and 6 letters.
    @Test func generatedDocumentsNeverShareAHash() async throws {
        let word = "syncwaaaaaa"
        #expect(
            ContentHash.sha256(SyncLabGenerator.textPDF(word: word, pages: 2))
                != ContentHash.sha256(SyncLabGenerator.textPDF(word: word, pages: 2)))
        let first = SyncLabGenerator.scanPages(word: word, pages: 1)
        let second = SyncLabGenerator.scanPages(word: word, pages: 1)
        #expect(first.pages != second.pages)
        #expect(
            ContentHash.sha256(SyncLabGenerator.largePDF(bytes: 100_000))
                != ContentHash.sha256(SyncLabGenerator.largePDF(bytes: 100_000)))

        let container = try makeInMemoryContainer()
        let importer = DocumentImporter(container: container, deviceID: deviceID)
        let a = await SyncLabGenerator.importText(word: word, pages: 1, importer: importer)
        let b = await SyncLabGenerator.importText(word: word, pages: 1, importer: importer)
        guard case .imported = a, case .imported = b else {
            Issue.record("a lab document was taken for a duplicate: \(a), \(b)")
            return
        }
        let unique = SyncLabGenerator.uniqueWord()
        #expect(unique.hasPrefix("syncw"))
        #expect(unique.count == 11)
        #expect(unique.dropFirst(5).allSatisfy { $0.isLowercase && $0.isLetter })
    }

    /// Only with `letter` does page 1 read like a letter (M1/M2); by default no page names a sender, a date or an
    /// amount the classifier could fill in, so the other cases measure sync, not classification (review A, B3 of
    /// PR #155).
    @Test func onlyTheLetterOptionGivesALetterPage() throws {
        let word = SyncLabGenerator.uniqueWord()
        // Markers of the letter page only. Not bare digits: every page has a random UUID line, whose hex digits can
        // contain "2026" (review B, N2 of PR #155).
        let letterWords = ["Stadtwerke Musterstadt", "Rechnung vom", "14.01.2026", "EUR"]
        for page in 0..<3 {
            let plain = SyncLabGenerator.lines(word: word, page: page).joined(separator: "\n")
            #expect(plain.contains(word))
            for letterWord in letterWords {
                #expect(!plain.contains(letterWord), "page \(page + 1) without the option has \(letterWord)")
            }
        }
        let letter = SyncLabGenerator.lines(word: word, page: 0, letter: true).joined(separator: "\n")
        #expect(letter.contains(word))
        for letterWord in letterWords { #expect(letter.contains(letterWord)) }

        let plainPDF = try #require(PDFDocument(data: SyncLabGenerator.textPDF(word: word, pages: 2)))
        #expect(plainPDF.string?.contains("Stadtwerke") == false)
        let letterPDF = try #require(PDFDocument(data: SyncLabGenerator.textPDF(word: word, pages: 2, letter: true)))
        #expect(letterPDF.string?.contains("Stadtwerke Musterstadt") == true)
    }

    /// The scan-like document comes through the importer's image path with the source `.scan`, one page per image.
    @Test func aScanLikeDocumentImportsAsAScan() async throws {
        let container = try makeInMemoryContainer()
        let importer = DocumentImporter(container: container, deviceID: deviceID)
        let word = SyncLabGenerator.uniqueWord()
        let outcome = await SyncLabGenerator.importScan(word: word, pages: 2, importer: importer)
        guard case .imported(let instanceID) = outcome else {
            Issue.record("not imported: \(outcome)")
            return
        }
        let document = try document(instanceID, in: container)
        #expect(document.source == .scan)
        #expect(document.pageCount == 2)
        #expect(document.originalFileName == "SyncLab-scan-\(word).jpg")
        #expect(document.processingDeviceID == deviceID)
    }

    /// The large file reaches its size with noise that does not compress, and opens.
    @Test func theLargeFileReachesItsSize() throws {
        let data = SyncLabGenerator.largePDF(bytes: 2_000_000)
        #expect(data.count >= 2_000_000)
        #expect(data.count < 4_000_000)
        #expect(PDFDocument(data: data)?.pageCount ?? 0 >= 1)
    }

    // MARK: Direct writes

    /// Direct write 1: a legacy document reads `done` with `textSource` none, an empty text record, a file, no
    /// thumbnail and this device's claim, all in one save; the re-queue pass takes it back to `pending`.
    @Test func aLegacyDocumentIsAsStepThreeLeftIt() throws {
        let container = try makeInMemoryContainer()
        let counter = SaveCounter(container)
        defer { counter.stop() }
        let instanceID = try SyncLabActions.insertLegacyDocument(
            in: container, deviceID: deviceID, word: "syncwlegacy", pages: 2)
        #expect(counter.saves.count == 1)
        let document = try document(instanceID, in: container)
        #expect(document.processingState == .done)
        #expect(document.textSource == .none)
        #expect(document.textSourceRaw == "")
        #expect(document.text?.extractedText == "")
        #expect(document.file?.pdfData != nil)
        #expect(document.thumbnail == nil)
        #expect(document.processingDeviceID == deviceID)
        #expect(document.pageCount == 2)
        #expect(SyncLabActions.isLabDocument(originalFileName: document.originalFileName))

        let suite = "DokumentumTests-SyncLabLegacy-\(UUID().uuidString)"
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let report = ProcessingRequeue(defaultsSuite: suite).run(in: container, deviceID: deviceID, now: Date())
        #expect(report.requeued == 1)
        #expect(try self.document(instanceID, in: container).processingState == .pending)
    }

    /// Direct write 3: "write large text" fills a `done` lab document's text past the processing cap; it refuses a
    /// document that is not `done` and one that is not a lab document, and writes nothing then.
    @Test func largeTextOnlyOnADoneLabDocument() async throws {
        let container = try makeInMemoryContainer()
        let legacy = try SyncLabActions.insertLegacyDocument(in: container, deviceID: deviceID, word: "w", pages: 1)
        let bytes = try SyncLabActions.writeLargeText(legacy, megabytes: 1, word: "syncwlarge", in: container)
        #expect(bytes >= 1_000_000)
        #expect(bytes > ExtractedText.byteLimit)
        let text = try #require(try document(legacy, in: container).text?.extractedText)
        #expect(text.hasPrefix("syncwlarge\n"))
        #expect(text.utf8.count == bytes)

        let importer = DocumentImporter(container: container, deviceID: deviceID)
        guard case .imported(let pending) = await SyncLabGenerator.importText(word: "w", pages: 1, importer: importer)
        else {
            Issue.record("not imported")
            return
        }
        #expect(throws: SyncLabActions.Refusal.notDone) {
            try SyncLabActions.writeLargeText(pending, megabytes: 1, word: "x", in: container)
        }
        let foreign = try insertForeignDocument(in: container, state: .done)
        #expect(throws: SyncLabActions.Refusal.notLabRecord) {
            try SyncLabActions.writeLargeText(foreign, megabytes: 1, word: "x", in: container)
        }
        #expect(try document(foreign, in: container).text?.extractedText == "Eigener Text")
        #expect(try document(pending, in: container).text?.extractedText == "")
    }

    /// Direct write 2: "delete directly" deletes a lab document with its file and text (cascade), and refuses any
    /// other document.
    @Test func deleteDirectlyOnlyOnALabDocument() throws {
        let container = try makeInMemoryContainer()
        let legacy = try SyncLabActions.insertLegacyDocument(in: container, deviceID: deviceID, word: "w", pages: 1)
        let foreign = try insertForeignDocument(in: container, state: .done)

        #expect(throws: SyncLabActions.Refusal.notLabRecord) {
            try SyncLabActions.deleteDirectly(foreign, in: container)
        }
        #expect(throws: SyncLabActions.Refusal.notFound) {
            try SyncLabActions.deleteDirectly(UUID(), in: container)
        }
        try SyncLabActions.deleteDirectly(legacy, in: container)

        let context = ModelContext(container)
        let documents = try context.fetch(FetchDescriptor<Document>())
        #expect(documents.map(\.instanceID) == [foreign])
        #expect(try context.fetchCount(FetchDescriptor<DocumentFile>()) == 1)
        #expect(try context.fetchCount(FetchDescriptor<DocumentText>()) == 1)
    }

    /// Direct write 5: a lab tag moves under another lab tag; a move that would make a cycle on this device and a tag
    /// that is not the lab's are refused.
    @Test func tagMovesOnlyBetweenLabTagsAndNeverIntoACycle() throws {
        let container = try makeInMemoryContainer()
        let editor = DocumentEditor(context: container.mainContext)
        let x = try editor.createMetadata(kind: .tag, name: SyncLabActions.labName("X"))
        let y = try editor.createMetadata(kind: .tag, name: SyncLabActions.labName("Y"))
        let own = try editor.createMetadata(kind: .tag, name: "Privat")

        try SyncLabActions.moveTag(x, under: y, in: container)
        #expect(throws: SyncLabActions.Refusal.cycle) {
            try SyncLabActions.moveTag(y, under: x, in: container)
        }
        #expect(throws: SyncLabActions.Refusal.notLabRecord) {
            try SyncLabActions.moveTag(own, under: y, in: container)
        }
        #expect(throws: SyncLabActions.Refusal.notLabRecord) {
            try SyncLabActions.moveTag(x, under: own, in: container)
        }
        let context = ModelContext(container)
        let tags = try context.fetch(FetchDescriptor<DokumentumCore.Tag>())
        #expect(tags.first { $0.instanceID == x }?.parent?.instanceID == y)
        #expect(tags.first { $0.instanceID == y }?.parent == nil)
        #expect(tags.first { $0.instanceID == own }?.parent == nil)

        try SyncLabActions.moveTag(x, under: nil, in: container)
        #expect(
            try ModelContext(container).fetch(FetchDescriptor<DokumentumCore.Tag>()).allSatisfy { $0.parent == nil })
    }

    /// Direct write 4: the reset clears this device's re-queue flag and nothing else.
    @Test func theRequeueResetClearsOnlyTheFlag() throws {
        let suite = "DokumentumTests-SyncLabRequeue-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: ProcessingRequeue.flagKey)
        defaults.set("KEEP", forKey: DeviceIdentity.defaultsKey)
        #expect(ProcessingRequeue(defaultsSuite: suite).isDone)

        SyncLabActions.resetRequeueFlag(defaultsSuite: suite)
        #expect(!ProcessingRequeue(defaultsSuite: suite).isDone)
        #expect(defaults.string(forKey: DeviceIdentity.defaultsKey) == "KEEP")
    }

    @Test func labNamesGetThePrefixOnce() {
        #expect(SyncLabActions.labName(" Stadtwerke ") == "SyncLab-Stadtwerke")
        #expect(SyncLabActions.labName("SyncLab-X") == "SyncLab-X")
        #expect(!SyncLabActions.isLabName("Stadtwerke"))
        #expect(!SyncLabActions.isLabDocument(originalFileName: "Rechnung.pdf"))
    }

    // MARK: Helpers

    /// A document that the lab did not create (no `SyncLab-` prefix), with a file and a text, as the maintainer's own.
    private func insertForeignDocument(in container: ModelContainer, state: ProcessingState) throws -> UUID {
        let context = ModelContext(container)
        let document = Document(title: "Rechnung")
        document.originalFileName = "Rechnung.pdf"
        document.processingState = state
        let file = DocumentFile(documentID: document.id, pdfData: SyntheticPDF.make(pages: [["Rechnung"]]))
        let text = DocumentText(documentID: document.id, extractedText: "Eigener Text")
        context.insert(document)
        context.insert(file)
        context.insert(text)
        document.file = file
        document.text = text
        try context.save()
        return document.instanceID
    }
}
