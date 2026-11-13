import DokumentumCoreTestSupport
import DokumentumKit
import DokumentumTestSupport
import Foundation
import Testing

@testable import DokumentumCore

/// Rendered letters through the real `DocumentStage` (#11, part 2; plan Tests part 2): every `SyntheticLetters`
/// entry rendered as a text PDF (`TestLetter`) gives its expected sender and date from the stage's text and
/// `firstPageLayout`, evaluated with its recipient among the known correspondents (B1.5). The letters drawn with
/// real PDF text are text pages, so the stub recogniser is never asked.
///
/// Five entries rendered as image-only pages (300 dpi scans) go through **real Vision**: German form B, the
/// authority letter, the probe-2 letter, the UK letter and the US invoice. They are in this file, serialized, so the
/// model loads once, and they are skipped with the reason where Vision cannot run, as `VisionRecognitionTests` are
/// (its preflight). Each wait has a safety net of 120 s (scaled); nothing compares durations.
@Suite(.serialized)
struct DetectionLetterTests {
    static let visionLetters = [
        "din-b-stadtbibliothek", "finanzamt", "probe2-bank-known", "uk-acme", "us-invoice",
    ]
    /// Measured on macOS 27.2 (Vision `.accurate`, de-DE and en-US, language correction): the 7 pt return-address
    /// line of these two scans is misread (`Stadtbibiothek Musterstadt`, `Finanzamt Musterstact`), so the
    /// structural name differs by a letter; their dates and the other three letters come out right. Recorded as a
    /// known issue (intermittent: another OS's Vision may read it right), never as a pass; the PR names it.
    static let visionReturnLineMisreads: Set<String> = ["din-b-stadtbibliothek", "finanzamt"]
    /// The letter's known correspondents, each with an id of its own.
    static func records(_ letter: SyntheticLetter) -> [MetadataMatcher.Record] {
        letter.knownNames.map { MetadataMatcher.Record(id: UUID(), name: $0) }
    }

    /// Expects the stage's result to give the letter's sender and date. `knownSenderIssue`: the sender's name is
    /// expected to differ, for that reason (an OCR misread); it is then still never the recipient.
    static func expectDetected(
        _ letter: SyntheticLetter, in result: ProcessingResult, knownSenderIssue: Comment? = nil,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        let layout = try #require(result.firstPageLayout, "no layout", sourceLocation: sourceLocation)
        let text = try #require(result.text, sourceLocation: sourceLocation).joined
        let date = IssueDateDetector.detect(in: text, createdAt: letter.createdAt)
        #expect(date == letter.date, "\(letter.id): \(text)", sourceLocation: sourceLocation)
        let records = records(letter)
        let sender = SenderDetector.detect(in: layout, known: records)
        let lines = layout.lines.map(\.text)
        if case .existing(_, let name) = sender {
            #expect(name != letter.recipient, "\(letter.id): never the recipient", sourceLocation: sourceLocation)
        }
        if let knownSenderIssue {
            withKnownIssue(knownSenderIssue, isIntermittent: true) {
                try expectSender(sender, of: letter, records: records, lines: lines, sourceLocation: sourceLocation)
            }
        } else {
            try expectSender(sender, of: letter, records: records, lines: lines, sourceLocation: sourceLocation)
        }
    }

    private static func expectSender(
        _ sender: DetectedSender?, of letter: SyntheticLetter, records: [MetadataMatcher.Record], lines: [String],
        sourceLocation: SourceLocation
    ) throws {
        switch letter.sender {
        case .known(let name):
            let record = try #require(records.first { $0.name == name }, sourceLocation: sourceLocation)
            #expect(
                sender == .existing(id: record.id, name: name), "\(letter.id): \(lines)", sourceLocation: sourceLocation
            )
        case .structural(let name):
            #expect(sender == .name(name), "\(letter.id): \(lines)", sourceLocation: sourceLocation)
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

    @Test(arguments: visionLetters)
    func aScannedLetterGivesItsSenderAndDateThroughVision(id: String) async throws {
        let letter = try #require(SyntheticLetters.letter(id))
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
            return
        }
        if let failure = await preflight.value {
            try Test.cancel("Vision cannot recognise text on this host: \(failure)")
        }

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
        try Self.expectDetected(
            letter, in: result,
            knownSenderIssue: Self.visionReturnLineMisreads.contains(id)
                ? "Vision misreads the 7 pt return-address line of this scan" : nil)
    }
}
