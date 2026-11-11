import DokumentumKit
import Foundation
import Testing

/// A PDF is known by its bytes (#86): `%PDF-` within the first 1,024 bytes, whatever comes before it.
struct ImportContentTests {
    static let header = Data("%PDF-1.7\n".utf8)

    static func header(after prefix: [UInt8]) -> Data {
        Data(prefix) + header
    }

    @Test(arguments: [
        ("at the start", header),
        ("behind a UTF-8 byte order mark", header(after: [0xEF, 0xBB, 0xBF])),
        ("behind three spaces", header(after: [0x20, 0x20, 0x20])),
        ("%PDF- ending at byte 1,023", header(after: [UInt8](repeating: 0x41, count: 1019))),
    ])
    func aPDFHeaderInTheWindowIsAPDF(_ label: String, data: Data) {
        #expect(ImportContent.isPDF(data), "\(label)")
    }

    @Test(arguments: [
        ("starting at byte 1,020", header(after: [UInt8](repeating: 0x41, count: 1020))),
        ("%PDF without the hyphen", Data("%PDF1.7\n".utf8)),
        ("empty", Data()),
        ("a JPEG's start", Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x49, 0x46])),
        ("a PNG's start", Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])),
        ("a TIFF's start", Data([0x49, 0x49, 0x2A, 0x00, 0x08, 0x00, 0x00, 0x00])),
    ])
    func anythingElseIsNot(_ label: String, data: Data) {
        #expect(!ImportContent.isPDF(data), "\(label)")
    }
}
