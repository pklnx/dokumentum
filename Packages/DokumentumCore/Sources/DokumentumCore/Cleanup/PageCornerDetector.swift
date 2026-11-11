import CoreGraphics
import Foundation
import Vision

/// Finds the corners of a page in a photo (#5, step 4); the cleanup sheet stubs it in tests.
public protocol PageCornerDetecting: Sendable {
    /// The page's corners in `image` (displayed orientation), or `nil` when no page was found that the
    /// detector accepts: the sheet then uses the full page.
    func detect(in image: CGImage) async -> PageCornerDetection?
}

/// A detected page.
public struct PageCornerDetection: Sendable, Hashable {
    /// Which Vision request found the page (T1).
    public enum Source: String, Sendable {
        case documentSegmentation, rectangles
    }

    public let quad: PageQuad
    public let confidence: Float
    public let source: Source

    public init(quad: PageQuad, confidence: Float, source: Source) {
        self.quad = quad
        self.confidence = confidence
        self.source = source
    }
}

/// Vision's page detection (T1): `VNDetectDocumentSegmentationRequest` first, and
/// `VNDetectRectanglesRequest` when it gives nothing acceptable. On the iOS simulator the segmentation request
/// returns the whole image with confidence 0 for every input, and on macOS it does so when there is no page
/// (probes on #5), so the confidence threshold is needed everywhere, and the simulator always takes the
/// fallback.
///
/// Accepted (T2): confidence at least `minimumConfidence`, a convex quad, at least `minimumArea` of the image.
/// Interactive, outside the processing queue's Vision gate (T6).
public struct VisionPageCornerDetector: PageCornerDetecting {
    public static let minimumConfidence: Float = 0.5
    public static let minimumArea: CGFloat = 0.1

    public init() {}

    @concurrent
    public func detect(in image: CGImage) async -> PageCornerDetection? {
        Self.detectNow(in: image)
    }

    /// The detection, synchronously, on the caller's thread.
    static func detectNow(in image: CGImage) -> PageCornerDetection? {
        if let segmented = segmentation(in: image), accepts(segmented) { return segmented }
        if let rectangle = rectangle(in: image), accepts(rectangle) { return rectangle }
        return nil
    }

    /// The segmentation request's answer as it is, before acceptance.
    static func segmentation(in image: CGImage) -> PageCornerDetection? {
        let request = VNDetectDocumentSegmentationRequest()
        guard perform(request, on: image), let observation = request.results?.first else { return nil }
        return PageCornerDetection(
            quad: quad(of: observation), confidence: observation.confidence, source: .documentSegmentation)
    }

    /// The rectangle request's best answer as it is, before acceptance.
    static func rectangle(in image: CGImage) -> PageCornerDetection? {
        let request = VNDetectRectanglesRequest()
        request.maximumObservations = 1
        request.minimumAspectRatio = 0.3
        guard perform(request, on: image), let observation = request.results?.first else { return nil }
        return PageCornerDetection(quad: quad(of: observation), confidence: observation.confidence, source: .rectangles)
    }

    /// T2: confident, convex, not too small.
    static func accepts(_ detection: PageCornerDetection) -> Bool {
        detection.confidence >= minimumConfidence && detection.quad.isConvex && detection.quad.area >= minimumArea
    }

    private static func perform(_ request: VNRequest, on image: CGImage) -> Bool {
        do {
            try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
            return true
        } catch {
            Log.importing.error("Page detection failed: \(Log.code(of: error), privacy: .public)")
            return false
        }
    }

    /// Vision's corners are normalised with the origin at the bottom left; a `PageQuad`'s at the top left.
    static func quad(of observation: VNRectangleObservation) -> PageQuad {
        func flipped(_ point: CGPoint) -> CGPoint { CGPoint(x: point.x, y: 1 - point.y) }
        return PageQuad(
            topLeft: flipped(observation.topLeft), topRight: flipped(observation.topRight),
            bottomRight: flipped(observation.bottomRight), bottomLeft: flipped(observation.bottomLeft))
    }
}
