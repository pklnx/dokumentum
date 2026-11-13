import CoreGraphics
import DokumentumCore
import DokumentumCoreTestSupport
import DokumentumKit
import DokumentumTestSupport
import Foundation
import SwiftData
import Synchronization
import Testing

// The processing tests' tools: a store on disk with documents in a given queue state, per-device failure counters
// in defaults suites of their own, a clock the test moves, and stages that count, fail or act in the middle.

/// The devices of the processing tests.
let deviceA = "DEVICE-A"
let deviceB = "DEVICE-B"
/// The time the processing tests start at.
let processingStart = Date(timeIntervalSinceReferenceDate: 830_000_000)
let hour: TimeInterval = 60 * 60

/// A clock the test sets.
final class TestClock: Sendable {
    private let time: Mutex<Date>

    init(_ start: Date = processingStart) {
        time = Mutex(start)
    }

    var now: Date { time.withLock { $0 } }
    var function: @Sendable () -> Date { { self.now } }

    func advance(by interval: TimeInterval) {
        time.withLock { $0.addTimeInterval(interval) }
    }
}

/// A document's row, as the tests compare it.
struct ProcessingRow: Equatable {
    var title: String
    var stateRaw: String
    var deviceID: String
    var claimedAt: Date?
    var pageCount: Int
    var isTrashed: Bool
    var correspondent: String?
    var fileInstanceID: UUID?
}

/// A store on disk for one test, with the failure counters' defaults suites it made. `remove()` in a `defer`.
final class ProcessingStore: Sendable {
    let store: TemporaryStore
    private let suites = Mutex<[String]>([])

    var container: ModelContainer { store.container }

    init() throws {
        store = try TemporaryStore()
    }

    func remove() {
        store.remove()
        for suite in suites.withLock({ $0 }) { UserDefaults().removePersistentDomain(forName: suite) }
    }

    /// A device's own failure counter, in a defaults suite of its own.
    func failures(_ device: String) -> ProcessingFailures {
        let suite = "DokumentumTests-Processing-\(device)-\(UUID().uuidString)"
        suites.withLock { $0.append(suite) }
        return ProcessingFailures(defaultsSuite: suite)
    }

    /// A queue whose stall watchdog sleeps on `watchdog`: a `ManualDebounce` nobody fires unless the test passes
    /// its own.
    func queue(
        _ device: String, failures: ProcessingFailures? = nil,
        stage: any ProcessingStage = DocumentStage(recognizer: StubRecognizer()),
        clock: TestClock, watchdog: ManualDebounce = ManualDebounce(), hooks: ProcessingQueue.Hooks = .init(),
        matchingBudget: MatchingBudget = testMatchingBudget
    ) -> ProcessingQueue {
        ProcessingQueue(
            container: container, deviceID: device, failures: failures ?? self.failures(device), stage: stage,
            matchingBudget: matchingBudget, watchdogSleep: watchdog.sleep, now: clock.function, hooks: hooks)
    }

    /// Inserts one document as the importer does (file and text in the same save), in the given queue state.
    /// `fileData: false` gives a file whose data has not arrived.
    @discardableResult
    func insert(
        title: String = "Document", created: Date = processingStart, stateRaw: String = "pending",
        device: String = "", claimedAt: Date? = nil, pages: Int = 2, pageCount: Int = 0, file: Bool = true,
        fileData: Bool = true, text: Bool = true, trashed: Bool = false, pdf: Data? = nil,
        textSource: TextSource = .none, thumbnail: Bool = false
    ) throws -> UUID {
        let context = ModelContext(container)
        let document = Document(title: title, createdAt: created)
        document.processingStateRaw = stateRaw
        document.processingDeviceID = device
        document.processingClaimedAt = claimedAt
        document.pageCount = pageCount
        document.textSource = textSource
        if trashed { document.deletedAt = created }
        context.insert(document)
        if file {
            let data = fileData ? pdf ?? TestPDF.make(pages: (1...pages).map { "Page \($0)" }) : nil
            let record = DocumentFile(documentID: document.id, pdfData: data, createdAt: created)
            context.insert(record)
            document.file = record
        }
        if text {
            let record = DocumentText(documentID: document.id, createdAt: created)
            context.insert(record)
            document.text = record
        }
        if thumbnail {
            let record = DocumentThumbnail(documentID: document.id, imageData: Data(count: 100), createdAt: created)
            context.insert(record)
            document.thumbnail = record
        }
        try context.save()
        return document.instanceID
    }

    /// Fetches the document in a new context, changes it and saves: another context's edit.
    func edit(_ id: UUID, _ change: (Document, ModelContext) throws -> Void) throws {
        let context = ModelContext(container)
        let document = try #require(try Self.fetch(id, in: context))
        try change(document, context)
        try context.save()
    }

    func row(_ id: UUID) throws -> ProcessingRow {
        let document = try #require(try Self.fetch(id, in: ModelContext(container)))
        return ProcessingRow(
            title: document.title, stateRaw: document.processingStateRaw, deviceID: document.processingDeviceID,
            claimedAt: document.processingClaimedAt, pageCount: document.pageCount,
            isTrashed: document.deletedAt != nil, correspondent: document.correspondent?.name,
            fileInstanceID: document.file?.instanceID)
    }

    /// The document's `textSource` and its text record's `extractedText` (`nil` without a text record).
    func text(of id: UUID) throws -> (source: TextSource, text: String?) {
        let document = try #require(try Self.fetch(id, in: ModelContext(container)))
        return (document.textSource, document.text?.extractedText)
    }

    /// The data of the document's linked file.
    func pdfData(of id: UUID) throws -> Data? {
        try Self.fetch(id, in: ModelContext(container))?.file?.pdfData
    }

    func fileSize(of id: UUID) throws -> Int? {
        try Self.fetch(id, in: ModelContext(container))?.fileSize
    }

    func contentHash(of id: UUID) throws -> String? {
        try Self.fetch(id, in: ModelContext(container))?.contentHash
    }

    /// The identifier of the document's linked file row.
    func fileIdentifier(of id: UUID) throws -> PersistentIdentifier? {
        try Self.fetch(id, in: ModelContext(container))?.file?.persistentModelID
    }

    static func fetch(_ id: UUID, in context: ModelContext) throws -> Document? {
        try context.fetch(FetchDescriptor<Document>(predicate: #Predicate { $0.instanceID == id })).first
    }
}

/// `DocumentStage` with a stub recogniser, with a count per call, an optional action in the middle (after the PDF was handed over, before
/// the result is written) and an optional number of failures first.
final class TestStage: ProcessingStage {
    private let calls = Mutex(0)
    private let failuresLeft: Mutex<Int>
    private let action: (@Sendable (Int) async throws -> Void)?
    let processed = TestSignal()

    struct Failure: Error {}

    /// - Parameters:
    ///   - failing: how many calls throw before the stage works.
    ///   - action: runs in each call with its number (from 1), before the stage's own work.
    init(failing: Int = 0, action: (@Sendable (Int) async throws -> Void)? = nil) {
        failuresLeft = Mutex(failing)
        self.action = action
    }

    var count: Int { calls.withLock { $0 } }

    func process(pdfData: Data, progress: @escaping ProcessingProgress) async throws -> ProcessingResult {
        let call = calls.withLock {
            $0 += 1
            return $0
        }
        defer { processed.fire() }
        try await action?(call)
        let fails = failuresLeft.withLock {
            guard $0 > 0 else { return false }
            $0 -= 1
            return true
        }
        if fails { throw Failure() }
        return try await DocumentStage(recognizer: StubRecognizer()).process(pdfData: pdfData, progress: progress)
    }
}

/// A stage that is a closure, for the tests that report progress themselves.
struct ClosureStage: ProcessingStage {
    let body: @Sendable (Data, ProcessingProgress) async throws -> ProcessingResult

    func process(pdfData: Data, progress: @escaping ProcessingProgress) async throws -> ProcessingResult {
        try await body(pdfData, progress)
    }
}

/// A recogniser that answers without Vision: `lines(call)` for its `call`-th page (from 1), by default one line
/// "Recognised <call>". Counts its calls and the pixel size of each image; `checkpoint`, when set, stops each call
/// at its `pass()` before it answers.
final class StubRecognizer: TextRecognizing {
    private let calls = Mutex<[CGSize]>([])
    private let lines: @Sendable (Int) -> [RecognizedLine]
    let checkpoint: Checkpoint?

    /// Lines without a box (`.zero`): the text layer cannot place them, so they never rewrite the file.
    init(checkpoint: Checkpoint? = nil, lines: @escaping @Sendable (Int) -> [String] = { ["Recognised \($0)"] }) {
        self.checkpoint = checkpoint
        self.lines = { call in lines(call).map { RecognizedLine(text: $0) } }
    }

    /// Lines with their boxes, as Vision gives them: the text layer draws them. Private, so the trailing closure of
    /// `init(checkpoint:lines:)` stays unambiguous; `boxed` makes one.
    private init(recognized: @escaping @Sendable (Int) -> [RecognizedLine], checkpoint: Checkpoint?) {
        self.checkpoint = checkpoint
        self.lines = recognized
    }

    /// `texts` on every page, one below the other from the top left, each in a box of half the page's width.
    static func boxed(_ texts: [String], checkpoint: Checkpoint? = nil) -> StubRecognizer {
        StubRecognizer(recognized: { _ in boxedLines(texts) }, checkpoint: checkpoint)
    }

    static func boxedLines(_ texts: [String]) -> [RecognizedLine] {
        texts.enumerated().map { index, text in
            RecognizedLine(
                text: text, boundingBox: CGRect(x: 0.1, y: 0.86 - CGFloat(index) * 0.04, width: 0.5, height: 0.03))
        }
    }

    var count: Int { calls.withLock { $0.count } }
    var imageSizes: [CGSize] { calls.withLock { $0 } }

    func recognizeText(in image: CGImage) async throws -> [RecognizedLine] {
        let call = calls.withLock {
            $0.append(CGSize(width: image.width, height: image.height))
            return $0.count
        }
        if let checkpoint { await checkpoint.pass() }
        return lines(call)
    }
}
