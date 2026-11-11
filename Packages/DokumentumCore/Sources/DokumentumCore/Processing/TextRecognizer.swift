import CoreGraphics
import Foundation
import Vision

/// One line of text a recogniser found on a page image.
public struct RecognizedLine: Equatable, Sendable {
    public var text: String
    /// Where the line is, normalised to the image (0…1) with the origin at the bottom left, as Vision gives it.
    /// The text layer (#6, part 3) draws the line into it.
    public var boundingBox: CGRect

    public init(text: String, boundingBox: CGRect = .zero) {
        self.text = text
        self.boundingBox = boundingBox
    }
}

/// Recognises the text on a rendered page (#6, part 2). `VisionTextRecognizer` in the app; tests pass a stub, so
/// only the few real-Vision tests depend on the model.
public protocol TextRecognizing: Sendable {
    /// The lines on `image`, in Vision's reading order. Throws when the recogniser fails.
    func recognizeText(in image: CGImage) async throws -> [RecognizedLine]
}

/// Vision's text recognition (T1 of #6): `RecognizeTextRequest`, `.accurate`, German and English, language
/// correction on. `.fast` found no line on the plan's test page (P-c). The only `import Vision` of the processing
/// queue; #5's corner detection uses Vision outside the queue.
public struct VisionTextRecognizer: TextRecognizing {
    /// The languages, in order of preference (T1).
    public static let languages = [Locale.Language(identifier: "de-DE"), Locale.Language(identifier: "en-US")]

    public init() {}

    /// The request every page is recognised with.
    public static func makeRequest() -> RecognizeTextRequest {
        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = languages
        request.usesLanguageCorrection = true
        return request
    }

    /// Whether this machine's Vision supports `languages`. A virtual Mac or a CI host may not; the real-Vision
    /// tests skip then (N8).
    public static var supportsLanguages: Bool {
        let supported = makeRequest().supportedRecognitionLanguages
        return languages.allSatisfy { language in
            supported.contains { $0.languageCode == language.languageCode && $0.region == language.region }
        }
    }

    public func recognizeText(in image: CGImage) async throws -> [RecognizedLine] {
        let observations = try await Self.makeRequest().perform(on: image)
        return observations.compactMap { observation in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            return RecognizedLine(text: candidate.string, boundingBox: observation.boundingBox.cgRect)
        }
    }
}
