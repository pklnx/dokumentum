import CoreGraphics
import DokumentumCoreTestSupport
import DokumentumKit
import DokumentumTestSupport
import Foundation
import ImageIO
import PDFKit
import SwiftData
import Testing
import UniformTypeIdentifiers

@testable import DokumentumCore

/// PDF bytes are a PDF whatever the label (#86): a PDF named or declared as an image keeps all its pages and is
/// stored byte for byte; image bytes keep going by their label, also when their metadata holds `%PDF-`.
extension DocumentImporterTests {
    static let threePages = TestPDF.make(pages: ["Vertrag", "Seite 2", "Seite 3"])

    /// A file name and a declared type, as Files, the drop (no type) or the share queue (a type) hand them over.
    struct Label: Sendable, CustomTestStringConvertible {
        let fileName: String
        let contentType: UTType?
        var byteOrderMark = false

        var testDescription: String {
            "\(fileName), \(contentType?.identifier ?? "no type")\(byteOrderMark ? ", behind a byte order mark" : "")"
        }
    }

    @Test(arguments: [
        Label(fileName: "Vertrag.png", contentType: nil),
        Label(fileName: "Vertrag.png", contentType: .png),
        Label(fileName: "Vertrag", contentType: .jpeg),
        Label(fileName: "Vertrag.pdf", contentType: .png),
        Label(fileName: "Vertrag.png", contentType: .png, byteOrderMark: true),
    ])
    func aPDFUnderAnImageLabelIsImportedAsThePDF(_ label: Label) async throws {
        let container = try TestSupport.makeContainer()
        let saves = SaveCounter(container)
        let data = label.byteOrderMark ? Data([0xEF, 0xBB, 0xBF]) + Self.threePages : Self.threePages

        let outcome = await Self.importer(container).importFile(
            data: data, fileName: label.fileName, contentType: label.contentType, source: .file)

        let documents = try Self.documents(in: container)
        let document = try #require(documents.first, "not imported: \(outcome)")
        #expect(documents.count == 1)
        #expect(outcome == .imported(instanceID: document.instanceID))
        #expect(saves.count == 1)
        #expect(document.pageCount == 3, "every page, not the first one rasterized")
        #expect(document.source == .file)
        #expect(document.file?.pdfData == data, "stored byte for byte")
        #expect(document.fileSize == data.count)
        #expect(document.contentHash == ContentHash.sha256(data))
        #expect(document.title == "Vertrag")
        #expect(document.originalFileName == label.fileName, "as received (T6)")
    }

    @Test func theSamePDFAgainIsADuplicateOfTheFullDocument() async throws {
        let container = try TestSupport.makeContainer()
        let importer = Self.importer(container)
        let first = await importer.importFile(
            data: Self.threePages, fileName: "Vertrag.png", contentType: .png, source: .file)
        guard case .imported(let id) = first else {
            Issue.record("not imported: \(first)")
            return
        }

        let again = await importer.importFile(
            data: Self.threePages, fileName: "Vertrag.pdf", contentType: .pdf, source: .file)

        #expect(again == .duplicate(of: id, title: "Vertrag", isTrashed: false))
        let documents = try Self.documents(in: container)
        #expect(documents.count == 1)
        #expect(documents.first?.pageCount == 3, "the duplicate's original holds every page")
    }

    /// No PDF name and no type, or a name of another type: the bytes decide (T1; #69).
    @Test(arguments: ["Scan", "Notiz.txt"])
    func aPDFWithoutAPDFNameIsAPDF(_ fileName: String) async throws {
        let container = try TestSupport.makeContainer()

        let outcome = await Self.importer(container).importFile(
            data: Self.threePages, fileName: fileName, contentType: nil, source: .file)

        let document = try #require(try Self.documents(in: container).first, "not imported: \(outcome)")
        #expect(outcome == .imported(instanceID: document.instanceID))
        #expect(document.pageCount == 3)
        #expect(document.source == .file)
        #expect(document.file?.pdfData == Self.threePages)
    }

    /// An image labelled as a PDF fails cleanly, as before (PQ1), also one with `%PDF-` in its metadata.
    @Test(arguments: [
        (MetadataImage.none, Label(fileName: "Bild.pdf", contentType: nil)),
        (.none, Label(fileName: "Bild", contentType: .pdf)),
        (.jpegComment, Label(fileName: "Bild.pdf", contentType: nil)),
    ])
    func anImageUnderAPDFLabelStillFails(_ image: MetadataImage, label: Label) async throws {
        let container = try TestSupport.makeContainer()
        let saves = SaveCounter(container)

        let outcome = await Self.importer(container).importFile(
            data: image.data, fileName: label.fileName, contentType: label.contentType, source: .file)

        #expect(outcome == .failed(.unreadablePDF))
        #expect(saves.count == 0)
        #expect(try ModelContext(container).fetchCount(FetchDescriptor<Document>()) == 0)
        #expect(try ModelContext(container).fetchCount(FetchDescriptor<DocumentFile>()) == 0)
    }

    /// `%PDF-` in an image's metadata, within the first KB: the bytes look like a PDF, PDFKit does not open
    /// them, and the label says image, so the import goes on as an image, as before #86 (plan review finding 1).
    @Test(arguments: [
        (MetadataImage.jpegComment, Label(fileName: "Bild.jpg", contentType: nil)),
        (.jpegComment, Label(fileName: "Bild", contentType: .jpeg)),
        (.jpegDescription, Label(fileName: "Bild.jpg", contentType: nil)),
        (.pngDescription, Label(fileName: "Bild.png", contentType: .png)),
    ])
    func anImageWithAPDFHeaderInItsMetadataIsStillAnImage(_ image: MetadataImage, label: Label) async throws {
        let data = image.data
        #expect(ImportContent.isPDF(data), "the bytes look like a PDF")
        #expect(PDFDocument(data: data) == nil, "and do not open as one")
        let container = try TestSupport.makeContainer()
        let saves = SaveCounter(container)

        let outcome = await Self.importer(container).importFile(
            data: data, fileName: label.fileName, contentType: label.contentType, source: .file)

        let document = try #require(try Self.documents(in: container).first, "not imported: \(outcome)")
        #expect(outcome == .imported(instanceID: document.instanceID))
        #expect(saves.count == 1)
        #expect(document.source == .image)
        #expect(document.pageCount == 1)
        #expect(document.title == "Bild")
        #expect(document.contentHash == ContentHash.sha256(data), "the hash of the image as received")
        let pdf = try #require(document.file?.pdfData)
        #expect(pdf != data, "a PDF built from the image")
        #expect(PDFDocument(data: pdf)?.pageCount == 1)
    }

    /// Generated images, some with the PDF header in their metadata (the plan review's probe cases).
    enum MetadataImage: String, Sendable, CustomTestStringConvertible {
        case none, jpegComment, jpegDescription, pngDescription

        var data: Data {
            switch self {
            case .none:
                return TestImage.make(width: 400, height: 300)
            case .jpegComment:
                // A COM segment right after the start of image: FF FE, its length (with the two length bytes),
                // the text.
                let jpeg = TestImage.make(width: 400, height: 300)
                let text = Data("made from %PDF-1.4 scan".utf8)
                let length = text.count + 2
                let segment = Data([0xFF, 0xFE, UInt8(length >> 8), UInt8(length & 0xFF)]) + text
                return jpeg.prefix(2) + segment + jpeg.dropFirst(2)
            case .jpegDescription:
                return Self.encode(
                    type: .jpeg,
                    properties: [
                        kCGImagePropertyTIFFDictionary: [
                            kCGImagePropertyTIFFImageDescription: "Converted from %PDF-1.7"
                        ]
                    ])
            case .pngDescription:
                return Self.encode(
                    type: .png,
                    properties: [kCGImagePropertyPNGDictionary: [kCGImagePropertyPNGDescription: "%PDF-1.5 export"]])
            }
        }

        var testDescription: String { rawValue }

        /// A generated image encoded again by ImageIO, with `properties` written into its metadata.
        private static func encode(type: UTType, properties: [CFString: Any]) -> Data {
            guard let source = CGImageSourceCreateWithData(TestImage.make(width: 400, height: 300) as CFData, nil),
                let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
            else { return Data() }
            let data = NSMutableData()
            guard
                let destination = CGImageDestinationCreateWithData(
                    data as CFMutableData, type.identifier as CFString, 1, nil)
            else { return Data() }
            CGImageDestinationAddImage(destination, image, properties as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { return Data() }
            return data as Data
        }
    }
}
