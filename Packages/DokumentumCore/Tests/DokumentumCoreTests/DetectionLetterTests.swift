import DokumentumCoreTestSupport
import DokumentumKit
import DokumentumTestSupport
import Foundation
import SwiftData
import Testing

@testable import DokumentumCore

/// Rendered letters through the real `DocumentStage` (#11, part 2; plan Tests part 2): every `SyntheticLetters`
/// entry rendered as a text PDF (`TestLetter`) gives its expected sender and date from the stage's text and
/// `firstPageLayout`, evaluated with its recipient among the known correspondents (B1.5). The letters drawn with
/// real PDF text are text pages, so the stub recogniser is never asked. The recipient is never the sender, neither as
/// a known record nor as a structural name.
///
/// Five entries rendered as image-only pages (300 dpi scans) go through **real Vision**: German form B, the
/// authority letter, the probe-2 letter, the UK letter and the US invoice; two of them again with their sender
/// known, through the queue. They are in this file, serialized, so the model loads once, and they are skipped with
/// the reason where Vision cannot run, as `VisionRecognitionTests` are (its preflight). Each wait has a safety net of
/// 120 s (scaled); nothing compares durations.
@Suite(.serialized)
struct DetectionLetterTests {
    static let visionLetters = [
        "din-b-stadtbibliothek", "finanzamt", "probe2-bank-known", "uk-acme", "us-invoice",
    ]
    /// **Recorded reads** of the 7 pt return-address lines of two scans, measured on macOS 27.2 (Vision `.accurate`,
    /// de-DE and en-US, language correction) and the same in every run there (reviews of #209: 7 of 7 and 5 of 5):
    /// the structural name comes out one letter off. The test accepts exactly the right name or exactly this read,
    /// and nothing else (`nil`, another name, the recipient). With the sender known, the known name in the letterhead
    /// wins (`aScannedLetterOfAKnownSenderLinksItAndCreatesNothing`).
    static let recordedReturnLineReads = [
        "din-b-stadtbibliothek": "Stadtbibiothek Musterstadt", "finanzamt": "Finanzamt Musterstact",
    ]

    /// The letter's known correspondents, each with an id of its own.
    static func records(_ letter: SyntheticLetter) -> [MetadataMatcher.Record] {
        letter.knownNames.map { MetadataMatcher.Record(id: UUID(), name: $0) }
    }

    /// Expects the stage's result to give the letter's sender and date. `alsoAccepted`: a structural name accepted
    /// besides the expected one (a recorded OCR read).
    static func expectDetected(
        _ letter: SyntheticLetter, in result: ProcessingResult, alsoAccepted: String? = nil,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        let layout = try #require(result.firstPageLayout, "no layout", sourceLocation: sourceLocation)
        let text = try #require(result.text, sourceLocation: sourceLocation).joined
        let date = IssueDateDetector.detect(in: text, createdAt: letter.createdAt)
        #expect(date == letter.date, "\(letter.id): \(text)", sourceLocation: sourceLocation)
        let records = records(letter)
        let sender = SenderDetector.detect(in: layout, known: records)
        let lines = layout.lines.map(\.text)
        let recipient = MetadataName.normalized(letter.recipient)
        switch sender {
        case .existing(_, let name), .name(let name):
            #expect(
                MetadataName.normalized(name) != recipient, "\(letter.id): never the recipient: \(name)",
                sourceLocation: sourceLocation)
        case nil:
            break
        }
        switch letter.sender {
        case .known(let name):
            let record = try #require(records.first { $0.name == name }, sourceLocation: sourceLocation)
            #expect(
                sender == .existing(id: record.id, name: name), "\(letter.id): \(lines)", sourceLocation: sourceLocation
            )
        case .structural(let name):
            let accepted = [name] + (alsoAccepted.map { [$0] } ?? [])
            #expect(
                accepted.map { DetectedSender.name($0) }.contains { $0 == sender }, "\(letter.id): \(lines)",
                sourceLocation: sourceLocation)
        case .none:
            #expect(sender == nil, "\(letter.id): \(lines)", sourceLocation: sourceLocation)
        }
    }

    @Test(arguments: SyntheticLetters.all.map(\.id))
    func aLetterRenderedAsATextPDFGivesItsSenderAndDate(id: String) async throws {
        let letter = try #require(SyntheticLetters.letter(id))
        let recognizer = StubRecognizer()
        let result = try await DocumentStage(recognizer: recognizer).process(pdfData: TestLetter.textPDF(letter)) {
            _, _ in
        }
        #expect(recognizer.count == 0, "a text page")
        #expect(result.text?.source == .pdfText)
        try Self.expectDetected(letter, in: result)
    }

    // MARK: Real Vision

    /// Cancels the test with the reason where Vision cannot run (`VisionRecognitionTests`' preflight); `false` when
    /// the preflight did not answer within the safety net (an issue is recorded).
    static func visionRuns() async throws -> Bool {
        guard VisionTextRecognizer.supportsLanguages else {
            try Test.cancel("Vision does not support de-DE and en-US here (as on a CI host)")
        }
        let probe = try #require(TestPDF.pageImage(lines: ["Probe"]))
        let probed = TestSignal()
        let preflight = Task {
            defer { probed.fire() }
            return await VisionRecognitionTests.preflight(probe)
        }
        guard await probed.wait(timeout: .seconds(120), "Vision's preflight did not answer within the safety net")
        else {
            preflight.cancel()
            return false
        }
        if let failure = await preflight.value {
            try Test.cancel("Vision cannot recognise text on this host: \(failure)")
        }
        return true
    }

    @Test(arguments: visionLetters)
    func aScannedLetterGivesItsSenderAndDateThroughVision(id: String) async throws {
        let letter = try #require(SyntheticLetters.letter(id))
        guard try await Self.visionRuns() else { return }

        let data = TestLetter.imagePDF(letter)
        let finished = TestSignal()
        let stage = Task {
            defer { finished.fire() }
            return try await DocumentStage(recognizer: VisionTextRecognizer()).process(pdfData: data) { _, _ in }
        }
        guard await finished.wait(timeout: .seconds(120), "Vision did not answer within the safety net") else {
            stage.cancel()
            return
        }
        let result = try await stage.value
        #expect(result.text?.source == .vision)
        try Self.expectDetected(letter, in: result, alsoAccepted: Self.recordedReturnLineReads[id])
    }

    /// Review B2 of #209: the two scans whose return-address line Vision misreads, with their sender **known**,
    /// through the queue (`done` path, the real stage with real Vision): the known record is linked, exactly, and no
    /// correspondent is created. Counter-proof: the old order (each zone's structural name before the next zone's
    /// known names) creates the misread name.
    @Test(arguments: ["din-b-stadtbibliothek", "finanzamt"])
    func aScannedLetterOfAKnownSenderLinksItAndCreatesNothing(id: String) async throws {
        let letter = try #require(SyntheticLetters.letter(id))
        guard case .structural(let senderName) = letter.sender else {
            Issue.record("\(id): a structural sender expected")
            return
        }
        guard try await Self.visionRuns() else { return }
        let store = try ProcessingStore()
        defer { store.remove() }
        let document = try store.insert(device: deviceA, claimedAt: processingStart, pdf: TestLetter.imagePDF(letter))
        try store.insertMetadata(.correspondent, letter.recipient)
        let sender = try store.insertMetadata(.correspondent, senderName)
        let queue = store.detectingQueue(stage: DocumentStage(recognizer: VisionTextRecognizer()), clock: TestClock())

        let finished = TestSignal()
        let run = Task {
            defer { finished.fire() }
            return await queue.run()
        }
        guard await finished.wait(timeout: .seconds(120), "Vision did not answer within the safety net") else {
            run.cancel()
            return
        }
        let report = await run.value

        #expect(report.done == 1)
        #expect(report.detectedCorrespondents == 1)
        #expect(report.createdCorrespondents == 0)
        #expect(try store.detected(document).correspondentID == sender)
        #expect(try store.correspondents() == [letter.recipient, senderName].sorted())
        #expect(try store.detected(document).documentDate == letterDate)
    }
}
