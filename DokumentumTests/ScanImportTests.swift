import CoreGraphics
import DokumentumCore
import DokumentumKit
import Foundation
import PDFKit
import SwiftData
import Testing

@testable import Dokumentum

#if os(iOS)
    import UIKit
#endif

/// A scan of rendered pages: each page white with a black marker square in the corner its index names
/// (`MarkedPage.corner(for:)`), so the order of the encoded pages can be read back. A `nil` page cannot be read.
struct RenderedScan: ScannedPages, @unchecked Sendable {
    let pages: [CGImage?]

    var pageCount: Int { pages.count }
    func image(at index: Int) -> CGImage? { pages[index] }
}

/// A rendered page with a marker in one corner; nothing is read from disk.
enum MarkedPage {
    enum Corner: CaseIterable {
        case topLeft, topRight, bottomRight, bottomLeft

        /// The marker's centre as a fraction of the page, from the top left.
        var point: CGPoint {
            switch self {
            case .topLeft: CGPoint(x: 0.1, y: 0.1)
            case .topRight: CGPoint(x: 0.9, y: 0.1)
            case .bottomRight: CGPoint(x: 0.9, y: 0.9)
            case .bottomLeft: CGPoint(x: 0.1, y: 0.9)
            }
        }
    }

    static func corner(for index: Int) -> Corner { Corner.allCases[index % Corner.allCases.count] }

    /// A white page of `width` × `height` px with a black square (a fifth of the shorter side) at `corner`.
    static func make(width: Int, height: Int, marker corner: Corner) -> CGImage {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let side = CGFloat(min(width, height)) / 5
        // CoreGraphics counts y from the bottom.
        let center = CGPoint(x: corner.point.x * CGFloat(width), y: (1 - corner.point.y) * CGFloat(height))
        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: center.x - side / 2, y: center.y - side / 2, width: side, height: side))
        return context.makeImage()!
    }

    /// The luminance (0…255) of `image` at a fraction of its size, from the top left.
    static func luminance(of image: CGImage, at point: CGPoint) -> Int {
        var pixel = [UInt8](repeating: 0, count: 4)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        pixel.withUnsafeMutableBytes { buffer in
            let context = CGContext(
                data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: space,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
            let x = point.x * CGFloat(image.width)
            let y = (1 - point.y) * CGFloat(image.height)
            context.draw(image, in: CGRect(x: -x, y: -y, width: CGFloat(image.width), height: CGFloat(image.height)))
        }
        return (Int(pixel[0]) + Int(pixel[1]) + Int(pixel[2])) / 3
    }

    /// The corner whose marker is black in `image`; `nil` when none or several are.
    static func markedCorner(of image: CGImage) -> Corner? {
        let dark = Corner.allCases.filter { luminance(of: image, at: $0.point) < 60 }
        return dark.count == 1 ? dark.first : nil
    }
}

/// Records what the controller showed while the importer ran.
@MainActor
final class ScanProbe {
    var controller: ImportController?
    var savingDuringImport: Bool?

    func record() { savingDuringImport = controller?.isSavingScan }
}

/// The scanner's import (#5, part 2, plan tests 10–12) through the `ScannedPages` seam: the camera is never
/// touched. What only a device shows (the camera, the permission prompt, a denied camera) is M2.
@MainActor
struct ScanImportTests {
    static let date = Date(timeIntervalSinceReferenceDate: 820_000_000)

    static func scan(_ count: Int) -> RenderedScan {
        RenderedScan(
            pages: (0..<count).map { MarkedPage.make(width: 1240, height: 1754, marker: MarkedPage.corner(for: $0)) })
    }

    // Test 10.
    @Test func aScanIsImportedAsOneScanDocumentThatOpensInTheInbox() async throws {
        let id = UUID()
        let probe = ScanProbe()
        let importer = StubImporter(
            images: ImageImportResult(outcome: .imported(instanceID: id)), onImportImages: { await probe.record() })
        let library = LibraryModel(source: SnapshotSource([ImportControllerTests.row(id)]))
        library.selection = .all
        let controller = ImportController(
            importer: importer, reader: StubReader(), library: library, now: { Self.date })
        probe.controller = controller
        controller.isScanning = true

        let report = await controller.importScan(Self.scan(2))

        let call = try #require(importer.imageImports.first)
        #expect(importer.imageImports.count == 1, "one document for the whole scan")
        #expect(call.source == .scan)
        #expect(call.title == ImportController.scanTitle(at: Self.date))
        #expect(call.items.count == 2)
        let corners = call.items.map {
            ImageCoding.orientedImage(from: $0, maxPixelSize: 4000).flatMap(MarkedPage.markedCorner)
        }
        #expect(corners == [.topLeft, .topRight], "two JPEG pages in scan order")
        #expect(report.entries.map(\.outcome) == [.imported(instanceID: id)])
        #expect(library.selection == .inbox)
        #expect(library.selectedDocumentID == id, "the new document opens (PQ1)")
        #expect(controller.notices.shown == nil, "nothing to report")
        #expect(!controller.isScanning, "the camera is closed")
        #expect(probe.savingDuringImport == true, "the window shows the scan being saved")
        #expect(!controller.isSavingScan, "and no longer once it is imported")
    }

    /// The whole way into the store with the app's importer: one Inbox document from the scan, as step 5 (#6)
    /// finds it at import (the plan's interface): source `scan`, pending, claimed by this device, an image-only
    /// PDF of the scanned pages, an empty text.
    @Test func aScanBecomesAPendingImageOnlyPDFInTheInbox() async throws {
        let container = try makeInMemoryContainer()
        let importer = DocumentImporter(container: container, deviceID: "DEVICE-A")
        let controller = ImportController(
            importer: importer, reader: StubReader(),
            library: LibraryModel(source: StoreLibrarySource(container: container)), now: { Self.date })

        let report = await controller.importScan(Self.scan(3))

        let documents = try container.mainContext.fetch(FetchDescriptor<Document>())
        let document = try #require(documents.first)
        #expect(documents.count == 1)
        #expect(report.entries.map(\.outcome) == [.imported(instanceID: document.instanceID)])
        #expect(document.source == .scan)
        #expect(document.title == ImportController.scanTitle(at: Self.date))
        #expect(document.isInbox)
        #expect(document.processingState == .pending)
        #expect(document.processingDeviceID == "DEVICE-A")
        #expect(document.pageCount == 3)
        #expect(document.textSourceRaw == "")
        #expect(document.text?.extractedText == "")
        let pdf = try #require(document.file?.pdfData.flatMap(PDFDocument.init(data:)))
        #expect(pdf.pageCount == 3)
        #expect((0..<3).allSatisfy { (pdf.page(at: $0)?.string ?? "").isEmpty }, "no text layer")
        #expect(controller.library.selectedDocumentID == document.instanceID)
    }

    @Test func theScanTitleNamesTheTime() {
        let time = Self.date.formatted(date: .numeric, time: .shortened)
        #expect(ImportController.scanTitle(at: Self.date) == String(localized: "Scan \(time)"))
        #expect(ImportController.scanTitle(at: Self.date).contains(time))
    }

    // Test 11.
    @Test func aPageThatCannotBeReadIsLeftOutAndCountedInTheNotice() async throws {
        let id = UUID()
        let importer = StubImporter(images: ImageImportResult(outcome: .imported(instanceID: id)))
        let controller = ImportController(
            importer: importer, reader: StubReader(),
            library: LibraryModel(source: SnapshotSource([ImportControllerTests.row(id)])))
        let page = MarkedPage.make(width: 600, height: 800, marker: .topLeft)

        let report = await controller.importScan(RenderedScan(pages: [page, nil, page]))

        #expect(importer.imageImports.first?.items.count == 2)
        #expect(report.entries.map(\.leftOut) == [1])
        let notice = try #require(controller.notices.shown)
        #expect(notice.message == String(localized: "One page could not be read and was left out."))

        let second = ImportController(
            importer: importer, reader: StubReader(), library: LibraryModel(source: SnapshotSource([])))
        await second.importScan(RenderedScan(pages: [nil, page, nil]))
        #expect(second.notices.shown?.message == String(localized: "\(2) pages could not be read and were left out."))
    }

    @Test func aScanWithoutAReadablePageIsOneFailureAndImportsNothing() async throws {
        let importer = StubImporter()
        let controller = ImportController(
            importer: importer, reader: StubReader(), library: LibraryModel(source: SnapshotSource([])),
            now: { Self.date })

        let report = await controller.importScan(RenderedScan(pages: [nil, nil]))

        #expect(importer.imageImports.isEmpty)
        #expect(report.entries.map(\.outcome) == [.failed(.couldNotRead)])
        #expect(report.entries.map(\.fileName) == [ImportController.scanTitle(at: Self.date)])
        #expect(controller.notices.shown != nil)
    }

    @Test func aScanWithoutPagesImportsNothingAndShowsNothing() async {
        let importer = StubImporter()
        let controller = ImportController(
            importer: importer, reader: StubReader(), library: LibraryModel(source: SnapshotSource([])))
        controller.isScanning = true

        let report = await controller.importScan(RenderedScan(pages: []))

        #expect(report.entries.isEmpty)
        #expect(importer.imageImports.isEmpty)
        #expect(controller.notices.shown == nil)
        #expect(!controller.isScanning)
    }

    @Test func aFailedScanClosesTheCameraAndShowsANotice() throws {
        let controller = ImportController(
            importer: StubImporter(), reader: StubReader(), library: LibraryModel(source: SnapshotSource([])))
        controller.isScanning = true

        controller.scanFailed(CocoaError(.featureUnsupported))

        #expect(!controller.isScanning)
        #expect(try #require(controller.notices.shown).title == String(localized: "Scanning failed"))
    }

    // Test 12.
    @Test func theEncoderKeepsThePageOrderAndAtMost2400Pixels() async throws {
        let pages: [CGImage?] = [
            MarkedPage.make(width: 3000, height: 2000, marker: .topLeft),
            MarkedPage.make(width: 2000, height: 3600, marker: .topRight),
            MarkedPage.make(width: 1000, height: 1400, marker: .bottomRight),
            MarkedPage.make(width: 2400, height: 1800, marker: .bottomLeft),
        ]

        let encoded = await ScanEncoder.jpegPages(RenderedScan(pages: pages))

        #expect(encoded.unreadable == 0)
        let images = try encoded.pages.map { try #require(ImageCoding.orientedImage(from: $0, maxPixelSize: 8000)) }
        #expect(images.map(MarkedPage.markedCorner) == [.topLeft, .topRight, .bottomRight, .bottomLeft])
        let sizes: [[Int]] = images.map { [$0.width, $0.height] }
        #expect(sizes == [[2400, 1600], [1333, 2400], [1000, 1400], [2400, 1800]])
        #expect(ScanEncoder.quality == 0.9 && ScanEncoder.maxPixelSize == 2400, "T4")
    }

    @Test func theEncoderCountsAPageItCannotRead() async {
        let page = MarkedPage.make(width: 100, height: 100, marker: .topLeft)
        let encoded = await ScanEncoder.jpegPages(RenderedScan(pages: [nil, page, nil]))
        #expect(encoded.pages.count == 1)
        #expect(encoded.unreadable == 2)
    }

    #if DEBUG
        /// The UI test's pages: two readable portrait A4 pages; the argument only on an in-memory store.
        @Test func theSyntheticScanIsTwoPortraitPagesOnAnInMemoryStoreOnly() throws {
            let scan = SyntheticScanPages.uiTest
            #expect(scan.pageCount == 2)
            for index in 0..<scan.pageCount {
                let page = try #require(scan.image(at: index))
                #expect(page.height > page.width)
            }
            #expect(scan.image(at: 2) == nil)
            #expect(
                !UITestScanSynthetic.isRequested(
                    arguments: [UITestScanSynthetic.argument, "YES"],
                    launchStore: LaunchStore(choice: .local, opened: .local)),
                "never into a store on disk")
            #expect(
                UITestScanSynthetic.isRequested(
                    arguments: [UITestScanSynthetic.argument, "YES"],
                    launchStore: LaunchStore(choice: .inMemory(seed: false), opened: .inMemory)))
        }
    #endif

    @Test func scanningIsOfferedOnlyWhereThereIsACamera() {
        let inMemory = LaunchStore(choice: .inMemory(seed: false), opened: .inMemory)
        #if os(macOS)
            #expect(
                ScanAvailability.current(launchStore: inMemory, arguments: ["-UITestScanSynthetic", "YES"])
                    == .unavailable)
        #else
            // The simulator has no document camera (VNDocumentCameraViewController.isSupported is false there).
            #expect(ScanAvailability.current(launchStore: inMemory, arguments: []) == .unavailable)
            #if DEBUG
                #expect(
                    ScanAvailability.current(launchStore: inMemory, arguments: ["-UITestScanSynthetic", "YES"])
                        == .synthetic)
                #expect(
                    ScanAvailability.current(
                        launchStore: LaunchStore(choice: .local, opened: .local),
                        arguments: ["-UITestScanSynthetic", "YES"]) == .unavailable)
            #endif
        #endif
    }

    #if os(iOS)
        /// A page that is not `.up` is drawn upright instead of losing its orientation (plan review of #5, finding 6).
        @Test func aCameraPageKeepsItsOrientation() throws {
            let stored = MarkedPage.make(width: 800, height: 600, marker: .topLeft)
            let up = UIImage(cgImage: stored, scale: 1, orientation: .up)
            #expect(ScannedImage.upright(up) === stored, "an upright page is used as it is")

            // `.right`: displayed turned a quarter clockwise, so the top-left marker shows at the top right.
            let turned = try #require(ScannedImage.upright(UIImage(cgImage: stored, scale: 1, orientation: .right)))
            #expect(turned.width == 600 && turned.height == 800)
            #expect(MarkedPage.markedCorner(of: turned) == .topRight)
        }
    #endif
}
