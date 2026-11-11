import DokumentumCoreTestSupport
import DokumentumKit
import DokumentumTestSupport
import Foundation
import Testing
import Vision

@testable import DokumentumCore

/// Real Vision (#6, part 2, T17, N8): an image-only page rendered in the test, through `DocumentStage` with
/// `VisionTextRecognizer`, as the app runs it. The first recognition in a process loads the model and took 24 s on
/// the plan's Mac (P-b), 4 s on the simulator (P-k), so the wait has a safety net of 120 s (scaled) and never
/// compares durations. Where Vision cannot recognise German and English (a virtual Mac, a CI host), or answers with
/// a Vision error, the test is skipped with the reason instead of failing.
struct VisionRecognitionTests {
    static let lines = ["Fälligkeit: 15.12.2026", "Straße des 17. Juni 4", "80331 München"]

    @Test func aScannedPageIsRecognisedWithItsUmlautsAndSharpS() async throws {
        guard VisionTextRecognizer.supportsLanguages else {
            try Test.cancel("Vision does not support de-DE and en-US here (as on a CI host)")
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

        let result: ProcessingResult
        do {
            result = try await stage.value
        } catch let error as VisionError {
            try Test.cancel("Vision is not available here: \(error)")
        }

        let text = try #require(result.text)
        #expect(text.source == .vision)
        for word in ["Fälligkeit", "Straße", "München"] {
            #expect(text.joined.contains(word), "\(word) not in \(text.joined)")
        }
    }
}
