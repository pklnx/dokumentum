import CoreGraphics
import DokumentumCore
import DokumentumKit
import DokumentumTestSupport
import Foundation
import ImageIO
import Synchronization
import Testing
import UniformTypeIdentifiers

@testable import Dokumentum

/// A page detector for the cleanup's tests: it answers from a script in call order, records how many detections
/// run at once and the sizes it was given, and holds the calls listed in `held` until the test releases them or
/// their task is cancelled.
final class StubPageDetector: PageCornerDetecting {
    private struct State {
        var running = 0
        var mostRunning = 0
        var calls = 0
        var sizes: [CGSize] = []
    }

    private let answers: [PageQuad?]
    private let gates: [Int: Checkpoint]
    private let state = Mutex(State())
    /// Fires when a call starts.
    let started = TestSignal()
    /// Fires when a held call ends because its task was cancelled.
    let cancelled = TestSignal()

    /// - Parameters:
    ///   - answers: the quad of each call in order; `nil`, or a call past the end, finds no page.
    ///   - held: the calls (0-based) that wait for `release(_:)` or their task's cancellation.
    init(answers: [PageQuad?] = [], held: Set<Int> = []) {
        self.answers = answers
        gates = Dictionary(uniqueKeysWithValues: held.map { ($0, Checkpoint()) })
    }

    var mostRunning: Int { state.withLock { $0.mostRunning } }
    var calls: Int { state.withLock { $0.calls } }
    var sizes: [CGSize] { state.withLock { $0.sizes } }

    func release(_ call: Int) { gates[call]?.release() }
    func releaseAll() { for gate in gates.values { gate.release() } }

    func detect(in image: CGImage) async -> PageCornerDetection? {
        let call = state.withLock { state in
            state.running += 1
            state.mostRunning = max(state.mostRunning, state.running)
            state.calls += 1
            state.sizes.append(CGSize(width: image.width, height: image.height))
            return state.calls - 1
        }
        defer { state.withLock { $0.running -= 1 } }
        started.fire()
        if let gate = gates[call] {
            await withTaskCancellationHandler {
                await gate.pass()
            } onCancel: {
                gate.release()
            }
            if Task.isCancelled { cancelled.fire() }
        }
        guard answers.indices.contains(call), let quad = answers[call] else { return nil }
        return PageCornerDetection(quad: quad, confidence: 1, source: .rectangles)
    }
}

/// Rendered photos for the cleanup's tests: `SyntheticPhotographedPage` (a page with a marker on a dark desk) and
/// a multi-page TIFF; no real photo.
enum CleanupPhotos {
    static func photo(_ line: String) -> Data {
        SyntheticPhotographedPage.make(lines: [line])
    }

    /// A TIFF with `frames` frames of 300 × 400 px.
    static func tiff(frames: Int) -> Data {
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(
            data as CFMutableData, UTType.tiff.identifier as CFString, frames, nil)!
        for frame in 0..<frames {
            let space = CGColorSpace(name: CGColorSpace.sRGB)!
            let context = CGContext(
                data: nil, width: 300, height: 400, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
            let shade = CGFloat(frame + 1) / CGFloat(frames + 1)
            context.setFillColor(CGColor(red: shade, green: shade, blue: shade, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 300, height: 400))
            CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        }
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }

    static let quadA = PageQuad(
        topLeft: CGPoint(x: 0.1, y: 0.1), topRight: CGPoint(x: 0.9, y: 0.12), bottomRight: CGPoint(x: 0.88, y: 0.9),
        bottomLeft: CGPoint(x: 0.12, y: 0.88))
    static let quadB = PageQuad(
        topLeft: CGPoint(x: 0.2, y: 0.15), topRight: CGPoint(x: 0.8, y: 0.15), bottomRight: CGPoint(x: 0.8, y: 0.85),
        bottomLeft: CGPoint(x: 0.2, y: 0.85))
}

/// The cleanup's model (#5, part 3, plan test 15; findings 3 and 5 of the plan review on #5) with a stub
/// detector and rendered photos.
@MainActor
struct PhotoCleanupModelTests {
    /// What a test sees of a model: a signal per applied detection and the pages in that order, a signal at the
    /// end of the detection and one per shown preview.
    @MainActor
    final class Probe {
        let applied = TestSignal()
        var appliedOrder: [Int] = []
        let ended = TestSignal()
        let previews = TestSignal()
    }

    /// A model of `images` with its probe.
    static func model(_ images: [Data], detector: StubPageDetector) async -> (PhotoCleanupModel, Probe) {
        let sources = await PhotoCleanupModel.pageSources(of: images)
        let model = PhotoCleanupModel(images: images, pages: sources.pages, detector: detector)
        let probe = Probe()
        model.detectionApplied = { id in
            probe.appliedOrder.append(id)
            probe.applied.fire()
        }
        model.detectionEnded = { probe.ended.fire() }
        model.previewShown = { _ in probe.previews.fire() }
        return (model, probe)
    }

    /// Finding 3: one detection at a time, the selected page first, then the others in order. Found edges are
    /// applied, no page found keeps the full page. Each call is held until the test saw it start, so detections
    /// that ran side by side would overlap.
    @Test func detectionRunsOnePageAtATimeSelectedFirstAndAppliesWhatItFinds() async {
        let detector = StubPageDetector(answers: [CleanupPhotos.quadA, nil, CleanupPhotos.quadB], held: [0, 1, 2])
        defer { detector.releaseAll() }
        let (model, probe) = await Self.model(
            ["eins", "zwei", "drei"].map(CleanupPhotos.photo), detector: detector)
        model.select(2)

        model.start()
        for call in 0..<3 {
            await detector.started.wait(for: call + 1)
            detector.release(call)
            await probe.applied.wait(for: call + 1)
        }
        await probe.ended.wait()

        #expect(detector.mostRunning == 1, "detections ran side by side")
        #expect(probe.appliedOrder == [2, 0, 1], "the selected page first, then the others in order")
        #expect(model.pages.map(\.edit.corners) == [.fullPage, CleanupPhotos.quadB, CleanupPhotos.quadA])
        #expect(model.pages.map(\.detection) == [.notFound, .found(CleanupPhotos.quadB), .found(CleanupPhotos.quadA)])
        #expect(
            detector.sizes.allSatisfy { max($0.width, $0.height) <= CGFloat(PhotoCleanupModel.previewPixelSize) },
            "detected on the preview size: \(detector.sizes)")
        #expect(model.pages.allSatisfy { $0.edit.filter == .enhanced }, "Enhanced by default (P3)")
        #expect(model.thumbnails.count == 3)
    }

    /// Rotate, filter and remove change only the selected page; removing the last page leaves nothing to save.
    @Test func rotateFilterAndRemoveChangeOnlyTheSelectedPage() async {
        let (model, _) = await Self.model(
            ["eins", "zwei", "drei"].map(CleanupPhotos.photo), detector: StubPageDetector())

        model.select(1)
        model.rotate()
        model.rotate()
        model.setFilter(.blackAndWhite)
        #expect(model.pages.map(\.edit.quarterTurns) == [0, 2, 0])
        #expect(model.pages.map(\.edit.filter) == [.enhanced, .blackAndWhite, .enhanced])

        model.select(0)
        for _ in 0..<5 { model.rotate() }
        #expect(model.pages.map(\.edit.quarterTurns) == [1, 2, 0], "five clockwise turns are one")

        model.select(1)
        model.removeSelectedPage()
        #expect(model.pages.map(\.id) == [0, 2])
        #expect(model.selectedPageID == 2, "the next page is selected")
        #expect(model.canSave)
        model.removeSelectedPage()
        #expect(model.selectedPageID == 0, "at the end, the one before")
        model.removeSelectedPage()
        #expect(model.pages.isEmpty)
        #expect(!model.canSave, "no page, no Save")
        #expect(model.editedImages.isEmpty)
    }

    /// The kept pages in order with their edits, a multi-page TIFF a page per frame (T8), each photo's bytes once.
    @Test func theEditedImagesAreTheKeptPagesInOrderWithTheirEdits() async throws {
        let first = CleanupPhotos.photo("eins")
        let tiff = CleanupPhotos.tiff(frames: 3)
        let last = CleanupPhotos.photo("drei")
        let (model, _) = await Self.model([first, tiff, last], detector: StubPageDetector())
        #expect(model.pages.map(\.frame) == [0, 0, 1, 2, 0])
        #expect(model.pages.map(\.image) == [0, 1, 1, 1, 2])

        model.select(2)
        model.removeSelectedPage()
        model.select(4)
        model.rotate()
        model.select(0)
        #expect(model.moveCorner(.topLeft, to: CGPoint(x: 0.1, y: 0.05)))

        let images = model.editedImages
        #expect(images.map(\.data) == [first, tiff, last])
        #expect(images.map { $0.pages.map(\.frame) } == [[0], [0, 2], [0]])
        let cropped = PageQuad(
            topLeft: CGPoint(x: 0.1, y: 0.05), topRight: CGPoint(x: 1, y: 0), bottomRight: CGPoint(x: 1, y: 1),
            bottomLeft: CGPoint(x: 0, y: 1))
        #expect(images[0].pages[0].edit == PageEdit(corners: cropped, filter: .enhanced))
        #expect(images[1].pages.map(\.edit) == [PhotoCleanupModel.initialEdit, PhotoCleanupModel.initialEdit])
        #expect(images[2].pages[0].edit == PageEdit(quarterTurns: 1, filter: .enhanced))
    }

    /// Finding 3: Save while the selected page's detection runs saves that page as it is (the full page), stops
    /// the detection, and no later page is detected.
    @Test func saveWhileADetectionRunsSavesThePageAsItIsAndStopsTheDetection() async throws {
        let id = UUID()
        let importer = StubImporter(images: ImageImportResult(outcome: .imported(instanceID: id)))
        let detector = StubPageDetector(answers: [CleanupPhotos.quadA, CleanupPhotos.quadA], held: [0])
        defer { detector.releaseAll() }
        let controller = ImportController(
            importer: importer, reader: StubReader(), library: LibraryModel(source: SnapshotSource([])),
            detector: detector, now: { ImportControllerTests.date })
        let photos = ["eins", "zwei"].map { StubPhoto(data: CleanupPhotos.photo($0)) }

        await controller.importPhotos(photos)
        await detector.started.wait()
        let report = await controller.saveCleanup()
        await detector.cancelled.wait()

        #expect(controller.cleanup == nil, "Save closes the cleanup")
        let call = try #require(importer.editedImports.first)
        let initial = PhotoCleanupModel.initialEdit
        #expect(call.items.map { $0.pages.map(\.edit) } == [[initial], [initial]])
        #expect(call.title == ImportController.photoTitle(at: ImportControllerTests.date))
        #expect(call.source == .image)
        #expect(report.entries.map(\.outcome) == [.imported(instanceID: id)])
        #expect(detector.calls == 1, "no page is detected after Save")
    }

    /// Cancel imports nothing, shows nothing and stops the detection.
    @Test func cancelImportsNothingAndStopsTheDetection() async {
        let importer = StubImporter()
        let detector = StubPageDetector(held: [0])
        defer { detector.releaseAll() }
        let controller = ImportController(
            importer: importer, reader: StubReader(), library: LibraryModel(source: SnapshotSource([])),
            detector: detector)

        await controller.importPhotos(["eins", "zwei"].map { StubPhoto(data: CleanupPhotos.photo($0)) })
        #expect(controller.cleanup != nil)
        await detector.started.wait()
        controller.cancelCleanup()
        await detector.cancelled.wait()

        #expect(controller.cleanup == nil)
        #expect(importer.editedImports.isEmpty && importer.imageImports.isEmpty, "nothing imported")
        #expect(controller.notices.shown == nil, "nothing shown")
        #expect(detector.calls == 1)
    }

    /// A detection that ends after the user moved a corner keeps the user's corners; Detected Edges applies it.
    @Test func aDetectionAfterTheUserSetTheCornersLeavesThem() async {
        let detector = StubPageDetector(answers: [CleanupPhotos.quadA], held: [0])
        defer { detector.releaseAll() }
        let (model, probe) = await Self.model([CleanupPhotos.photo("eins")], detector: detector)
        #expect(model.edgesAction == .detectedEdges(available: false), "nothing detected yet")

        model.start()
        await detector.started.wait()
        #expect(model.moveCorner(.bottomRight, to: CGPoint(x: 0.9, y: 0.9)))
        let moved = model.pages[0].edit.corners
        detector.release(0)
        await probe.applied.wait()

        #expect(model.pages[0].edit.corners == moved, "the user's corners stay")
        #expect(model.pages[0].detection == .found(CleanupPhotos.quadA))
        #expect(model.edgesAction == .fullPage)
        model.useFullPage()
        #expect(model.pages[0].edit.corners == .fullPage)
        #expect(model.edgesAction == .detectedEdges(available: true))
        model.useDetectedEdges()
        #expect(model.pages[0].edit.corners == CleanupPhotos.quadA)
        model.stop()
    }

    /// A move that would cross the page is refused and the last convex corners stay (`QuadGeometry.moving`).
    @Test func aCornerMoveThatCrossesThePageIsRefused() async {
        let (model, _) = await Self.model([CleanupPhotos.photo("eins")], detector: StubPageDetector())
        #expect(!model.moveCorner(.topLeft, to: CGPoint(x: 0.9, y: 0.95)))
        #expect(model.pages[0].edit.corners == .fullPage)
        #expect(!model.pages[0].cornersSetByUser)
    }

    /// At most three previews: the selected page and its neighbours; the selected one is shown with its filter.
    @Test func onlyTheSelectedPageAndItsNeighboursHavePreviews() async {
        let (model, probe) = await Self.model(
            ["1", "2", "3", "4", "5"].map(CleanupPhotos.photo), detector: StubPageDetector())
        model.select(3)
        model.start()
        await probe.ended.wait()
        await probe.previews.wait()

        #expect(Set(model.previews.keys).isSubset(of: [2, 3, 4]), "\(model.previews.keys.sorted())")
        #expect(model.previews[3] != nil)
        #expect(model.filteredPreview?.pageID == 3)
        #expect(model.filteredPreview?.filter == .enhanced)
        #expect(model.thumbnails.count == 5)

        model.setFilter(.grayscale)
        await probe.previews.wait(for: 2)
        #expect(model.filteredPreview?.filter == .grayscale)
        model.stop()
        #expect(model.previews.isEmpty && model.thumbnails.isEmpty && model.filteredPreview == nil)
    }

    /// The UI test's synthetic pick: two rendered photos, a page each; never into a store on disk.
    @Test func theSyntheticPickIsTwoRenderedPhotos() async throws {
        var images: [Data] = []
        for photo in UITestCleanupSynthetic.photos { images.append(try #require(try await photo.loadData())) }
        let sources = await PhotoCleanupModel.pageSources(of: images)
        #expect(sources.pages.count == 2 && sources.unreadable == 0)
        #expect(sources.pages.map(\.size) == [CGSize(width: 1200, height: 1600), CGSize(width: 1200, height: 1600)])
        #expect(
            !UITestCleanupSynthetic.isRequested(
                arguments: [UITestCleanupSynthetic.argument, "YES"],
                launchStore: LaunchStore(choice: .local, opened: .local)),
            "never into a store on disk")
        #expect(
            UITestCleanupSynthetic.isRequested(
                arguments: [UITestCleanupSynthetic.argument, "YES"],
                launchStore: LaunchStore(choice: .inMemory(seed: false), opened: .inMemory)))
    }
}
