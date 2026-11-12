import CoreGraphics
import DokumentumCoreTestSupport
import DokumentumKit
import DokumentumTestSupport
import Foundation
import PDFKit
import Testing

@testable import DokumentumCore

/// Real Vision (#6, part 2, T17, N8): an image-only page rendered in the test, through `DocumentStage` with
/// `VisionTextRecognizer`, as the app runs it, and the text layer drawn from Vision's boxes (part 3). The first recognition in a process loads the model and took 24 s on
/// the plan's Mac (P-b), 4 s on the simulator (P-k), so each wait has a safety net of 120 s (scaled) and never
/// compares durations.
///
/// **Skipped only where Vision itself cannot run** (a CI host or a virtual Mac; review 5866563252, B1): before the
/// stage, a preflight asks `VisionTextRecognizer` alone to recognise a small rendered image. If Vision does not list
/// German and English, or the preflight throws anything (Xcode Cloud's macOS host throws an `e5rtError` of the ML
/// runtime, not a `VisionError`), the test is cancelled with the reason. Whatever the stage throws afterwards fails
/// the test, so a regression in the stage's own code is never skipped. On the development Mac the test passes.
struct VisionRecognitionTests {
    static let lines = ["Fälligkeit: 15.12.2026", "Straße des 17. Juni 4", "80331 München"]

    /// Vision alone on a small page image: `nil` when it answered, else the error it threw, as the skip reason.
    static func preflight(_ image: CGImage) async -> String? {
        do {
            _ = try await VisionTextRecognizer().recognizeText(in: image)
            return nil
        } catch {
            return "\(error)"
        }
    }

    @Test func aScannedPageIsRecognisedWithItsUmlautsAndSharpS() async throws {
        guard VisionTextRecognizer.supportsLanguages else {
            try Test.cancel("Vision does not support de-DE and en-US here (as on a CI host)")
        }
        let probe = try #require(TestPDF.pageImage(lines: ["Probe"]))
        let probed = TestSignal()
        let preflight = Task {
            defer { probed.fire() }
            return await Self.preflight(probe)
        }
        guard await probed.wait(timeout: .seconds(120), "Vision's preflight did not answer within the safety net")
        else {
            preflight.cancel()
            return
        }
        if let failure = await preflight.value {
            try Test.cancel("Vision cannot recognise text on this host: \(failure)")
        }

        let data = TestPDF.makeImageOnly(pages: [Self.lines])
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
        let text = try #require(result.text)
        #expect(text.source == .vision)
        for word in ["Fälligkeit", "Straße", "München"] {
            #expect(text.joined.contains(word), "\(word) not in \(text.joined)")
        }
        // The text layer (#6, part 3) from Vision's own boxes: the file finds the words.
        let layeredData = try #require(result.layeredPDF, "no text layer")
        let layered = try #require(PDFDocument(data: layeredData))
        for word in ["Fälligkeit", "Straße", "München"] {
            #expect(layered.findString(word, withOptions: []).count == 1, "\(word) not found in the layered file")
        }
    }
}
