import CoreGraphics
import CoreText
import Foundation
import PDFKit

/// The invisible text layer (#6, part 3; plan Approach 2 with Revision 1, B1, N5, R1-N1): the recognised lines
/// drawn invisibly into a copy of the PDF, so the stored file itself becomes searchable. The rewrite replaces the
/// stored PDF and no original is kept (the maintainer's P4), so **it happens only when every rule below holds**;
/// otherwise the stored bytes stay exactly as they are and the text goes only into `DocumentText`. When a case is
/// unclear, the answer is "no rewrite".
///
/// A rewrite needs (`refusal`):
/// - at least one recognised line to add (a page that gave no lines is no reason to rewrite);
/// - a PDF that is not encrypted and has no `DokumentumTextLayer` key in its Info dictionary (an earlier layer, N5:
///   a layered PDF is never layered again);
/// - a catalog with no keys beyond `/Type` and `/Pages` (what a `CGContext` writes, P-l): embedded files (`/Names`,
///   `/AF`, e-invoices), `/PageLabels`, XMP `/Metadata`, `/StructTreeRoot`, `/Outlines`, `/AcroForm`, and anything
///   else mean no rewrite;
/// - page dictionaries with no keys beyond `/Type /Parent /Contents /Resources /MediaBox /CropBox /Rotate`:
///   annotations, extra boxes, `/StructParents` and anything else mean no rewrite;
/// - no font without an embedded font program (`/FontFile`, `/FontFile2`, `/FontFile3`) in any page's resources,
///   their form XObjects, patterns or Type 3 fonts (R1-N1): a redraw substitutes such a font (P-m).
///
/// The rewrite (P-l): every page redrawn with `drawPDFPage` into a `CGContext` page with the source's media and
/// crop box, each recognised line drawn invisibly into its bounding box (font size the box height, scaled to the
/// box width); then a PDFKit pass sets every page's rotation from the source, copies the source's Info attributes
/// and adds `DokumentumTextLayer` = `1`, and writes `dataRepresentation()`.
///
/// **The guard** (`verify`, all must hold, else the original stays): the new PDF opens, unencrypted; the same page
/// count; its catalog and pages within the allow-lists; per page the same media box, crop box and rotation; the
/// same Info attributes and Info keys plus the marker; every line of each source page's own text still in the
/// page's text; every drawn line in its page's text; and every page rendered pixel-identical to the source at
/// 300 px on the long side (crop box, rotation applied, RGB).
public struct TextLayer: Sendable {
    /// The Info key that marks a layered PDF (N5).
    public static let markerKey = "DokumentumTextLayer"
    /// The catalog keys a rewrite carries: what a `CGContext` writes.
    public static let catalogKeys: Set<String> = ["Type", "Pages"]
    /// The page keys a rewrite carries.
    public static let pageKeys: Set<String> = [
        "Type", "Parent", "Contents", "Resources", "MediaBox", "CropBox", "Rotate",
    ]
    /// The long side of the guard's renders, in pixels.
    public static let guardLongSide = 300
    /// How deep the font check follows resources (form XObjects in form XObjects, patterns, Type 3 fonts). Deeper
    /// counts as a font that is not embedded: no rewrite.
    static let resourceDepth = 8

    /// Why the stored PDF was kept as it is.
    public enum Kept: Equatable, Sendable {
        /// No recognised line to add.
        case noLines
        /// CoreGraphics cannot open the PDF.
        case unreadable
        case encrypted
        /// It carries `DokumentumTextLayer` (an earlier layer).
        case marked
        /// A catalog key outside `catalogKeys`.
        case catalogKey(String)
        /// A key outside `pageKeys` on the page at `page` (from 0).
        case pageKey(page: Int, key: String)
        /// A font without an embedded font program on the page at `page`.
        case nonEmbeddedFont(page: Int)
        /// The redraw or the PDFKit pass gave no PDF.
        case rewriteFailed
        /// The rewritten PDF did not pass the guard.
        case guardFailed(GuardFailure)

        /// A fixed name for the log (never a key or text from the PDF).
        public var code: String {
            switch self {
            case .noLines: "noLines"
            case .unreadable: "unreadable"
            case .encrypted: "encrypted"
            case .marked: "marked"
            case .catalogKey: "catalogKey"
            case .pageKey: "pageKey"
            case .nonEmbeddedFont: "nonEmbeddedFont"
            case .rewriteFailed: "rewriteFailed"
            case .guardFailed(let failure): "guard.\(failure.code)"
            }
        }
    }

    /// What the guard found different in the rewritten PDF.
    public enum GuardFailure: Equatable, Sendable {
        case unreadable
        case pageCount
        /// Its catalog or a page holds a key outside the allow-lists.
        case structure
        case boxes(page: Int)
        case rotation(page: Int)
        case attributes
        /// A line of the source page's own text is not in the page's text any more.
        case sourceText(page: Int)
        /// A drawn line is not in its page's text.
        case line(page: Int)
        case pixels(page: Int)

        var code: String {
            switch self {
            case .unreadable: "unreadable"
            case .pageCount: "pageCount"
            case .structure: "structure"
            case .boxes: "boxes"
            case .rotation: "rotation"
            case .attributes: "attributes"
            case .sourceText: "sourceText"
            case .line: "line"
            case .pixels: "pixels"
            }
        }
    }

    public enum Outcome: Equatable, Sendable {
        /// The rewritten PDF, which passed the guard.
        case layered(Data)
        case kept(Kept)
    }

    /// Tests only: changes the rewritten PDF before the guard sees it, to show the guard rejects it.
    let alterRewrite: (@Sendable (Data) -> Data)?

    public init() {
        alterRewrite = nil
    }

    init(alterRewrite: @escaping @Sendable (Data) -> Data) {
        self.alterRewrite = alterRewrite
    }

    /// The layered PDF for `data`, or why it is kept. `document` is `data` opened by PDFKit (the stage's, kept alive
    /// by the caller, P-h); `lines` the recognised lines per page index, their boxes normalised to the page as
    /// rendered (crop box, rotation applied, origin bottom left), as `PageText.render` and Vision give them.
    /// `progress` is called once per page of the redraw and of the guard (the stall watchdog).
    public func apply(
        to data: Data, document: PDFDocument, lines: [Int: [RecognizedLine]], progress: () -> Void = {}
    ) -> Outcome {
        let drawable = lines.mapValues(Self.drawable).filter { !$0.value.isEmpty }
        guard !drawable.isEmpty else { return .kept(.noLines) }
        guard let source = Self.cgDocument(data) else { return .kept(.unreadable) }
        if let refusal = Self.refusal(of: source, document: document) { return .kept(refusal) }
        guard var rewritten = Self.rewrite(source, document: document, lines: drawable, progress: progress) else {
            return .kept(.rewriteFailed)
        }
        if let alterRewrite { rewritten = alterRewrite(rewritten) }
        if let failure = Self.verify(
            rewritten, against: source, document: document, lines: drawable, progress: progress)
        {
            return .kept(.guardFailed(failure))
        }
        return .layered(rewritten)
    }

    /// The lines that can be drawn: with text, and a box of positive size inside the page (clipped to it).
    static func drawable(_ lines: [RecognizedLine]) -> [RecognizedLine] {
        lines.compactMap { line in
            let text = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let box = line.boundingBox.standardized.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
            guard !text.isEmpty, !box.isNull, box.width > 0, box.height > 0 else { return nil }
            return RecognizedLine(text: text, boundingBox: box)
        }
    }

    static func cgDocument(_ data: Data) -> CGPDFDocument? {
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGPDFDocument(provider)
    }

    // MARK: - The rules before a rewrite

    /// Why `source` must not be rewritten, or `nil` when it may be.
    static func refusal(of source: CGPDFDocument, document: PDFDocument) -> Kept? {
        if source.isEncrypted || document.isEncrypted || document.isLocked { return .encrypted }
        if isMarked(source, document: document) { return .marked }
        guard let catalog = source.catalog else { return .unreadable }
        if let key = keys(of: catalog).sorted().first(where: { !catalogKeys.contains($0) }) {
            return .catalogKey(key)
        }
        guard source.numberOfPages == document.pageCount, source.numberOfPages > 0 else { return .unreadable }
        for index in 0..<source.numberOfPages {
            guard let page = source.page(at: index + 1), let dictionary = page.dictionary else { return .unreadable }
            if let key = keys(of: dictionary).sorted().first(where: { !pageKeys.contains($0) }) {
                return .pageKey(page: index, key: key)
            }
            if hasFontWithoutProgram(resources(of: dictionary), depth: 0) { return .nonEmbeddedFont(page: index) }
        }
        return nil
    }

    /// Whether the Info dictionary has the marker key, whatever its value.
    static func isMarked(_ source: CGPDFDocument, document: PDFDocument) -> Bool {
        if document.documentAttributes?[markerKey] != nil { return true }
        guard let info = source.info else { return false }
        return keys(of: info).contains(markerKey)
    }

    static func keys(of dictionary: CGPDFDictionaryRef) -> Set<String> {
        var keys: Set<String> = []
        CGPDFDictionaryApplyBlock(
            dictionary,
            { key, _, _ in
                keys.insert(String(cString: key))
                return true
            }, nil)
        return keys
    }

    /// A page's resources, inherited from its page tree nodes when the page has none.
    static func resources(of page: CGPDFDictionaryRef) -> CGPDFDictionaryRef? {
        var node: CGPDFDictionaryRef? = page
        for _ in 0..<64 {
            guard let current = node else { return nil }
            if let resources = dictionary(current, "Resources") { return resources }
            node = dictionary(current, "Parent")
        }
        return nil
    }

    /// Whether `resources` (or what they use, `depth` levels down) hold a font without an embedded program, or
    /// something the check cannot read.
    static func hasFontWithoutProgram(_ resources: CGPDFDictionaryRef?, depth: Int) -> Bool {
        guard let resources else { return false }
        guard depth < resourceDepth else { return true }
        if let fonts = dictionary(resources, "Font") {
            var missing = false
            forEachValue(of: fonts) { value in
                guard let font = dictionaryValue(value), isEmbedded(font, depth: depth) else {
                    missing = true
                    return false
                }
                return true
            }
            if missing { return true }
        }
        for name in ["XObject", "Pattern"] {
            guard let entries = dictionary(resources, name) else { continue }
            var missing = false
            forEachValue(of: entries) { value in
                // Images and shading patterns have no resources; forms and tiling patterns may.
                guard let stream = streamValue(value), let streamDictionary = CGPDFStreamGetDictionary(stream),
                    let inner = dictionary(streamDictionary, "Resources")
                else { return true }
                missing = hasFontWithoutProgram(inner, depth: depth + 1)
                return !missing
            }
            if missing { return true }
        }
        return false
    }

    /// Whether `font` carries its program: a Type 3 font is drawn by the PDF itself (its own resources are
    /// checked), a Type 0 font by its descendant, every other one by `/FontFile`, `/FontFile2` or `/FontFile3` in its
    /// descriptor. A font the check cannot read counts as not embedded.
    static func isEmbedded(_ font: CGPDFDictionaryRef, depth: Int) -> Bool {
        switch name(font, "Subtype") {
        case "Type3":
            return !hasFontWithoutProgram(dictionary(font, "Resources"), depth: depth + 1)
        case "Type0":
            var array: CGPDFArrayRef?
            var descendant: CGPDFDictionaryRef?
            guard CGPDFDictionaryGetArray(font, "DescendantFonts", &array), let array, CGPDFArrayGetCount(array) == 1,
                CGPDFArrayGetDictionary(array, 0, &descendant), let descendant
            else { return false }
            return hasProgram(descendant)
        default:
            return hasProgram(font)
        }
    }

    static func hasProgram(_ font: CGPDFDictionaryRef) -> Bool {
        guard let descriptor = dictionary(font, "FontDescriptor") else { return false }
        return ["FontFile", "FontFile2", "FontFile3"].contains { (key: String) -> Bool in
            var stream: CGPDFStreamRef?
            return CGPDFDictionaryGetStream(descriptor, key, &stream)
        }
    }

    static func dictionary(_ dictionary: CGPDFDictionaryRef, _ key: String) -> CGPDFDictionaryRef? {
        var value: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(dictionary, key, &value) else { return nil }
        return value
    }

    static func name(_ dictionary: CGPDFDictionaryRef, _ key: String) -> String? {
        var value: UnsafePointer<CChar>?
        guard CGPDFDictionaryGetName(dictionary, key, &value), let value else { return nil }
        return String(cString: value)
    }

    static func forEachValue(of dictionary: CGPDFDictionaryRef, _ body: (CGPDFObjectRef) -> Bool) {
        CGPDFDictionaryApplyBlock(dictionary, { _, value, _ in body(value) }, nil)
    }

    static func dictionaryValue(_ object: CGPDFObjectRef) -> CGPDFDictionaryRef? {
        var value: CGPDFDictionaryRef?
        guard CGPDFObjectGetValue(object, .dictionary, &value) else { return nil }
        return value
    }

    static func streamValue(_ object: CGPDFObjectRef) -> CGPDFStreamRef? {
        var value: CGPDFStreamRef?
        guard CGPDFObjectGetValue(object, .stream, &value) else { return nil }
        return value
    }

    // MARK: - The rewrite

    /// The redraw with the invisible lines, then the PDFKit pass (rotation, attributes, marker). `nil` when either
    /// step gives no PDF.
    static func rewrite(
        _ source: CGPDFDocument, document: PDFDocument, lines: [Int: [RecognizedLine]], progress: () -> Void
    ) -> Data? {
        guard let redrawn = redraw(source, document: document, lines: lines, progress: progress),
            let pass = PDFDocument(data: redrawn), pass.pageCount == document.pageCount
        else { return nil }
        for index in 0..<pass.pageCount {
            guard let page = pass.page(at: index), let original = document.page(at: index) else { return nil }
            page.rotation = original.rotation
        }
        var attributes = document.documentAttributes ?? [:]
        attributes[markerKey] = "1"
        pass.documentAttributes = attributes
        return pass.dataRepresentation()
    }

    static func redraw(
        _ source: CGPDFDocument, document: PDFDocument, lines: [Int: [RecognizedLine]], progress: () -> Void
    ) -> Data? {
        let data = NSMutableData()
        guard let first = source.page(at: 1), let consumer = CGDataConsumer(data: data as CFMutableData) else {
            return nil
        }
        var firstBox = first.getBoxRect(.mediaBox)
        guard let context = CGContext(consumer: consumer, mediaBox: &firstBox, nil) else { return nil }
        for index in 0..<source.numberOfPages {
            guard let page = source.page(at: index + 1), let original = document.page(at: index) else { return nil }
            var mediaBox = page.getBoxRect(.mediaBox)
            var cropBox = page.getBoxRect(.cropBox)
            let boxes: [CFString: Any] = [
                kCGPDFContextMediaBox: Data(bytes: &mediaBox, count: MemoryLayout<CGRect>.size),
                kCGPDFContextCropBox: Data(bytes: &cropBox, count: MemoryLayout<CGRect>.size),
            ]
            context.beginPDFPage(boxes as CFDictionary)
            context.drawPDFPage(page)
            if let pageLines = lines[index] { drawInvisibly(pageLines, on: original, in: context) }
            context.endPDFPage()
            progress()
        }
        context.closePDF()
        return data as Data
    }

    /// Draws `lines` invisibly in the page's own space: each normalised box is placed on the page as rendered (crop
    /// box, rotation) and mapped back through the inverse of the page's display transform.
    static func drawInvisibly(_ lines: [RecognizedLine], on page: PDFPage, in context: CGContext) {
        var size = page.bounds(for: .cropBox).size
        if page.rotation % 180 != 0 { size = CGSize(width: size.height, height: size.width) }
        context.saveGState()
        defer { context.restoreGState() }
        context.concatenate(page.transform(for: .cropBox).inverted())
        context.setTextDrawingMode(.invisible)
        for line in lines {
            let box = CGRect(
                x: line.boundingBox.minX * size.width, y: line.boundingBox.minY * size.height,
                width: line.boundingBox.width * size.width, height: line.boundingBox.height * size.height)
            let font = CTFontCreateWithName("Helvetica" as CFString, box.height, nil)
            let attributed = NSAttributedString(
                string: line.text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
            let typeset = CTLineCreateWithAttributedString(attributed)
            var descent: CGFloat = 0
            let width = CGFloat(CTLineGetTypographicBounds(typeset, nil, &descent, nil))
            guard width > 0 else { continue }
            context.saveGState()
            context.translateBy(x: box.minX, y: box.minY + descent)
            context.scaleBy(x: box.width / width, y: 1)
            context.textPosition = .zero
            CTLineDraw(typeset, context)
            context.restoreGState()
        }
    }

    // MARK: - The guard

    /// What differs between the rewritten PDF and the source, or `nil` when nothing does.
    static func verify(
        _ rewritten: Data, against source: CGPDFDocument, document: PDFDocument, lines: [Int: [RecognizedLine]],
        progress: () -> Void
    ) -> GuardFailure? {
        guard let output = PDFDocument(data: rewritten), !output.isLocked, !output.isEncrypted,
            let outputCG = cgDocument(rewritten), !outputCG.isEncrypted
        else { return .unreadable }
        guard output.pageCount == document.pageCount, outputCG.numberOfPages == document.pageCount else {
            return .pageCount
        }
        guard let catalog = outputCG.catalog, keys(of: catalog).isSubset(of: catalogKeys) else { return .structure }
        for index in 0..<outputCG.numberOfPages {
            guard let dictionary = outputCG.page(at: index + 1)?.dictionary,
                keys(of: dictionary).isSubset(of: pageKeys)
            else { return .structure }
        }
        guard attributesMatch(output, outputCG, source: source, document: document) else { return .attributes }
        for index in 0..<document.pageCount {
            guard let before = document.page(at: index), let after = output.page(at: index) else { return .pageCount }
            guard before.bounds(for: .mediaBox) == after.bounds(for: .mediaBox),
                before.bounds(for: .cropBox) == after.bounds(for: .cropBox)
            else { return .boxes(page: index) }
            guard before.rotation == after.rotation else { return .rotation(page: index) }
            let text = compact(after.string ?? "")
            let sourceLines = (before.string ?? "").split(whereSeparator: \.isNewline).map { compact(String($0)) }
            guard sourceLines.allSatisfy({ $0.isEmpty || text.contains($0) }) else { return .sourceText(page: index) }
            guard (lines[index] ?? []).allSatisfy({ text.contains(compact($0.text)) }) else {
                return .line(page: index)
            }
        }
        for index in 0..<document.pageCount {
            let same = autoreleasepool { () -> Bool in
                guard let before = document.page(at: index), let after = output.page(at: index),
                    let expected = pixels(of: before), let actual = pixels(of: after)
                else { return false }
                return expected == actual
            }
            guard same else { return .pixels(page: index) }
            progress()
        }
        return nil
    }

    /// The same Info attributes as the source plus the marker, as PDFKit reads them, and the same Info keys plus the
    /// marker, as CoreGraphics reads them (an entry PDFKit does not show is still compared by its key).
    static func attributesMatch(
        _ output: PDFDocument, _ outputCG: CGPDFDocument, source: CGPDFDocument, document: PDFDocument
    ) -> Bool {
        var expected = document.documentAttributes ?? [:]
        expected[markerKey] = "1"
        guard NSDictionary(dictionary: expected).isEqual(to: output.documentAttributes ?? [:]) else { return false }
        let sourceKeys = source.info.map(keys(of:)) ?? []
        let outputKeys = outputCG.info.map(keys(of:)) ?? []
        return outputKeys == sourceKeys.union([markerKey])
    }

    /// `text` without whitespace: the extracted text of a page may break or join lines differently.
    static func compact(_ text: String) -> String {
        String(text.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) }.map(Character.init))
    }

    /// The page rendered in RGB on white at `guardLongSide` pixels on the long side, crop box and rotation applied:
    /// its bytes, for the guard's compare.
    static func pixels(of page: PDFPage) -> [UInt8]? {
        guard let size = PageText.renderSize(of: page, longSide: guardLongSide),
            let context = CGContext(
                data: nil, width: size.width, height: size.height, bitsPerComponent: 8, bytesPerRow: size.width * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: size.width, height: size.height))
        var bounds = page.bounds(for: .cropBox).size
        if page.rotation % 180 != 0 { bounds = CGSize(width: bounds.height, height: bounds.width) }
        context.scaleBy(x: CGFloat(size.width) / bounds.width, y: CGFloat(size.height) / bounds.height)
        page.draw(with: .cropBox, to: context)
        guard let data = context.data else { return nil }
        return Array(
            UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self), count: size.width * size.height * 4))
    }
}
