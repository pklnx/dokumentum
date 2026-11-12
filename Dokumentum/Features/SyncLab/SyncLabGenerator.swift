#if DEBUG
    import CoreGraphics
    import DokumentumCore
    import DokumentumKit
    import Foundation
    import UniformTypeIdentifiers

    /// The Sync lab's synthetic documents (plan of #31, Approach 3, "Create"). Nothing is read from disk, and nothing
    /// is a real document. Every document carries a fresh random line, so the importer's duplicate check never matches
    /// two of them, and a fresh unique word (`syncw` plus 6 letters) that search can find.
    ///
    /// The lab imports them through the app's importer (`DocumentImporter`, on iOS behind `BackgroundImportNotifying`):
    /// the claim, the file, the thumbnail and the empty text record come in one save, as in production. Only the
    /// legacy document is a direct write (`SyncLabActions.insertLegacyDocument`).
    enum SyncLabGenerator {
        /// What the lab creates.
        enum Kind: String, CaseIterable, Identifiable {
            /// `SyntheticPDF` pages with real text.
            case text
            /// Rendered page images, imported as a scan: Vision OCR and the text layer run.
            case scan
            /// A PDF of about 20 MB, of noise images that do not compress (C7).
            case large
            /// As step 3 left documents (direct write 1).
            case legacy

            var id: String { rawValue }

            var label: String {
                switch self {
                case .text: "Text document"
                case .scan: "Scan-like document"
                case .large: "Large file"
                case .legacy: "Legacy document"
                }
            }
        }

        /// The size of the large file (C7).
        static let largeFileBytes = 20_000_000

        /// A fresh unique word: `syncw` and 6 random lowercase letters.
        static func uniqueWord() -> String {
            let letters = Array("abcdefghijklmnopqrstuvwxyz")
            return "syncw" + String((0..<6).map { _ in letters.randomElement() ?? "a" })
        }

        /// The lines of page `index` (from 0) of a lab document with `word`: every page has the word and a random
        /// line. With `letter`, page 1 reads like a letter (sender, date, amount) for the classification cases M1/M2;
        /// without it, no page gives the classifier a correspondent, a type or a date to suggest (review A, B3 of
        /// PR #155).
        static func lines(word: String, page index: Int, letter: Bool = false) -> [String] {
            let random = "Zufall \(UUID().uuidString)"
            if index == 0, letter {
                return [
                    "SyncLab \(word)", "Stadtwerke Musterstadt", "Rechnung vom 14.01.2026",
                    "Abschlag Strom November, Betrag 62,00 EUR", "Suchwort \(word)", random,
                ]
            }
            if index == 0 {
                return ["SyncLab \(word)", "Seite 1", "Suchwort \(word)", random]
            }
            return ["Seite \(index + 1)", "Suchwort \(word) auf Seite \(index + 1)", random]
        }

        /// A text PDF of `pages` pages; with `letter`, page 1 is the letter page.
        static func textPDF(word: String, pages: Int, letter: Bool = false) -> Data {
            SyntheticPDF.make(pages: (0..<max(1, pages)).map { lines(word: word, page: $0, letter: letter) })
        }

        /// The pages of a scan-like document, rendered as `SyntheticScanPages` draws them.
        static func scanPages(word: String, pages: Int, letter: Bool = false) -> SyntheticScanPages {
            SyntheticScanPages(pages: (0..<max(1, pages)).map { lines(word: word, page: $0, letter: letter) })
        }

        /// A PDF of at least `bytes` bytes: pages of seeded noise images (RGB, 8 bit), which do not compress. A new
        /// seed per call, so two never share a hash.
        static func largePDF(bytes: Int) -> Data {
            let width = 1500
            let perPage = min(max(bytes, 3 * width), 5_400_000)
            let height = max(1, (perPage + 3 * width - 1) / (3 * width))
            let pages = max(1, Int((Double(bytes) / Double(3 * width * height)).rounded(.up)))
            var generator = SplitMix64(seed: UInt64.random(in: .min ... .max))
            let data = NSMutableData()
            var mediaBox = CGRect(x: 0, y: 0, width: 595, height: 842)
            guard let consumer = CGDataConsumer(data: data as CFMutableData),
                let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil),
                let space = CGColorSpace(name: CGColorSpace.sRGB)
            else { return Data() }
            for _ in 0..<pages {
                var pixels = [UInt8](repeating: 0, count: width * height * 3)
                pixels.withUnsafeMutableBytes { buffer in
                    var offset = 0
                    while offset < buffer.count {
                        var value = generator.next()
                        let count = min(8, buffer.count - offset)
                        withUnsafeBytes(of: &value) { bytes in
                            for index in 0..<count { buffer[offset + index] = bytes[index] }
                        }
                        offset += count
                    }
                }
                guard let provider = CGDataProvider(data: Data(pixels) as CFData),
                    let image = CGImage(
                        width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 24, bytesPerRow: width * 3,
                        space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                        provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
                else { continue }
                context.beginPDFPage(nil)
                context.draw(image, in: mediaBox)
                context.endPDFPage()
            }
            context.closePDF()
            return data as Data
        }

        // MARK: Imports

        /// The `originalFileName` of a lab document of `kind`.
        static func fileName(_ kind: Kind, word: String) -> String {
            switch kind {
            case .text: "\(SyncLabActions.prefix)text-\(word).pdf"
            case .scan: "\(SyncLabActions.prefix)scan-\(word).jpg"
            case .large: "\(SyncLabActions.prefix)large-\(word).pdf"
            case .legacy: "\(SyncLabActions.prefix)legacy-\(word).pdf"
            }
        }

        /// Imports a text document through `importer`.
        static func importText(
            word: String, pages: Int, letter: Bool = false, importer: any DocumentImporting
        ) async -> ImportOutcome {
            let pdf = await Task.detached { textPDF(word: word, pages: pages, letter: letter) }.value
            return await importer.importFile(
                data: pdf, fileName: fileName(.text, word: word), contentType: .pdf, source: .file)
        }

        /// Imports a scan-like document through `importer`: the pages encoded as a scan is (`ScanEncoder`), as one
        /// document with the source `.scan`.
        static func importScan(
            word: String, pages: Int, letter: Bool = false, importer: any DocumentImporting
        ) async -> ImportOutcome {
            let encoded = await ScanEncoder.jpegPages(scanPages(word: word, pages: pages, letter: letter))
            guard !encoded.pages.isEmpty else { return .failed(.unreadableImage) }
            return await importer.importImages(
                encoded.pages, fileName: fileName(.scan, word: word), title: "SyncLab scan \(word)", source: .scan
            ).outcome
        }

        /// Imports the large file through `importer`.
        static func importLarge(word: String, bytes: Int, importer: any DocumentImporting) async -> ImportOutcome {
            let pdf = await Task.detached { largePDF(bytes: bytes) }.value
            return await importer.importFile(
                data: pdf, fileName: fileName(.large, word: word), contentType: .pdf, source: .file)
        }
    }

    /// A small seeded random number generator (SplitMix64): fast enough for 20 MB of noise.
    struct SplitMix64: RandomNumberGenerator {
        private var state: UInt64

        init(seed: UInt64) {
            state = seed
        }

        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var value = state
            value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
            value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
            return value ^ (value >> 31)
        }
    }
#endif
