import CoreGraphics
import DokumentumCoreTestSupport
import DokumentumKit
import DokumentumTestSupport
import Foundation
import PDFKit
import SwiftData
import Synchronization
import Testing
import UniformTypeIdentifiers

@testable import DokumentumCore

/// The invisible text layer (#6, part 3; plan Approach 2 with Revision 1, B1, N5, R1-N1). The stage runs with a stub
/// recogniser whose lines have boxes. Every "no rewrite" case expects the stored file **byte-identical** and the text
/// in `DocumentText`; every PDF is written in the test (`TestPDF`), never read from disk.
struct TextLayerTests {
    static let lines = ["Fälligkeit: 15.12.2026", "80331 München"]

    private func stage(
        _ texts: [String] = Self.lines, textLayer: TextLayer = TextLayer()
    ) -> DocumentStage {
        DocumentStage(recognizer: StubRecognizer.boxed(texts), textLayer: textLayer)
    }

    private func layer(_ data: Data, texts: [String] = Self.lines) throws -> TextLayer.Outcome {
        let document = try #require(PDFDocument(data: data))
        var lines: [Int: [RecognizedLine]] = [:]
        for index in 0..<document.pageCount where PageText.embeddedText(of: document.page(at: index)!) == nil {
            lines[index] = StubRecognizer.boxedLines(texts)
        }
        return TextLayer().apply(to: data, document: document, lines: lines)
    }

    private func catalogKeys(_ data: Data) throws -> Set<String> {
        let document = try #require(TextLayer.cgDocument(data))
        return TextLayer.keys(of: try #require(document.catalog))
    }

    // MARK: - The rewrite

    /// The main case, a scan: the layer keeps page count, boxes and every pixel, and the file finds its lines.
    @Test func anImageOnlyPDFGetsALayerThatLooksTheSameAndFindsItsLines() async throws {
        let source = TestPDF.makeImageOnly(pages: [Self.lines, ["Seite 2"]])
        let counter = ProgressCounter()

        let result = try await stage().process(pdfData: source) { _, _ in counter.add() }
        let progress = counter.count

        let layered = try #require(result.layeredPDF)
        let before = try #require(PDFDocument(data: source))
        let after = try #require(PDFDocument(data: layered))
        #expect(after.pageCount == 2)
        for index in 0..<2 {
            let page = try #require(after.page(at: index))
            let original = try #require(before.page(at: index))
            #expect(page.bounds(for: .mediaBox) == original.bounds(for: .mediaBox))
            #expect(page.bounds(for: .cropBox) == original.bounds(for: .cropBox))
            #expect(TextLayer.pixels(of: page) == TextLayer.pixels(of: original), "page \(index) looks different")
        }
        #expect(after.findString("Fälligkeit", withOptions: []).count == 2, "one hit per page")
        #expect(after.findString("munchen", withOptions: [.caseInsensitive, .diacriticInsensitive]).count == 2)
        for line in Self.lines { #expect(after.string?.contains(line) == true, "\(line) not in the file's text") }
        #expect(after.documentAttributes?[TextLayer.markerKey] as? String == "1")
        #expect(try catalogKeys(layered) == ["Pages", "Type"])
        // 2 pages recognised, then 2 for the redraw and 2 for the guard, and the first report.
        #expect(progress == 1 + 2 + 2 + 2, "the redraw and the guard report progress (N1)")
    }

    static let born = "Rechnung Nummer 2026-0042"

    /// A born-digital page (its font embedded, as a `CGContext` writes it) beside a scanned page: the file is
    /// layered, and the text page keeps its own text.
    @Test func aMixedPDFWithAnEmbeddedFontIsLayeredAndKeepsItsText() async throws {
        let source = TestPDF.make(contents: [.text(Self.born), .image(Self.lines)])

        let result = try await stage().process(pdfData: source) { _, _ in }

        let layered = try #require(result.layeredPDF, "not layered")
        let after = try #require(PDFDocument(data: layered))
        #expect(after.page(at: 0)?.string?.contains(Self.born) == true)
        #expect(after.findString("Fälligkeit", withOptions: []).count == 1, "only the scanned page is layered")
    }

    /// The PDF the importer builds from photos (`PDFBuilder`, JPEG pages): the main case qualifies.
    @Test func aPDFBuiltFromImagesGetsALayer() async throws {
        let container = try TestSupport.makeContainer()
        let image = TestImage.make(width: 1240, height: 1754)
        let imported = await DocumentImporter(container: container, deviceID: deviceA).importImages(
            [image], fileName: "Foto.png")
        guard case .imported(let id) = imported.outcome else {
            Issue.record("not imported: \(imported)")
            return
        }
        let data = try #require(
            try ModelContext(container).fetch(FetchDescriptor<Document>(predicate: #Predicate { $0.instanceID == id }))
                .first?.file?.pdfData)

        guard case .layered(let layered) = try layer(data) else {
            Issue.record("not layered: \(try layer(data))")
            return
        }
        // Its Info (Quartz's Producer and dates in `Z00'00'`) exactly as it was, plus the marker (B1 of PR #134).
        #expect(try Self.info(layered) == TextLayer.markedInfo(try Self.info(data)))
    }

    /// The Info entries of `data` as CoreGraphics reads them.
    static func info(_ data: Data) throws -> [[UInt8]: TextLayer.InfoValue] {
        let document = try #require(TextLayer.cgDocument(data))
        return try #require(TextLayer.info(of: document))
    }

    /// B1 of PR #134: every Info entry keeps its type and exact value through the rewrite (PDFKit alone turns
    /// Keywords into an array, writes dates in this device's time zone and booleans as integers).
    @Test(arguments: [
        "/Keywords (Rechnung; Steuer 2026, wichtig)",
        "/Flag true /Count 3 /Ratio 0.25 /Trapped /False /Custom [1 (zwei) /Drei << /Vier null >>]",
        "/CreationDate (D:20260315103000Z) /ModDate (D:20260315103000-05'00')",
        "/CreationDate (D:20260315103000)",
        "/CreationDate (D:20260315) /ModDate (D:2017)",
        "/Title (Rechnung M\\374nchen) /Author (\\376\\377\\000A\\000\\344)",
    ])
    func anInfoEntryKeepsItsTypeAndExactValue(_ entries: String) throws {
        let source = TestPDF.makeRaw(pages: [.bar()], info: "<< \(entries) >>")

        let outcome = try layer(source)

        guard case .layered(let layered) = outcome else {
            Issue.record("not layered: \(outcome)")
            return
        }
        let before = try Self.info(source)
        #expect(!before.isEmpty)
        #expect(try Self.info(layered) == TextLayer.markedInfo(before))
        if entries.hasPrefix("/Keywords") {
            // The document holds its Info: keep it alive while the string is read.
            let document = try #require(TextLayer.cgDocument(layered))
            let info = try #require(document.info)
            var keywords: CGPDFStringRef?
            #expect(CGPDFDictionaryGetString(info, "Keywords", &keywords), "Keywords is no longer a string")
            #expect(keywords.flatMap { CGPDFStringCopyTextString($0) as String? } == "Rechnung; Steuer 2026, wichtig")
            withExtendedLifetime(document) {}
        }
    }

    /// A raw-written page with nothing beyond the allow-lists is layered: the control for the fixtures below, which
    /// add one key each.
    @Test func aPlainRawPDFIsLayered() throws {
        let outcome = try layer(TestPDF.makeRaw(pages: [.bar(), .blank]))

        guard case .layered(let data) = outcome else {
            Issue.record("not layered: \(outcome)")
            return
        }
        #expect(PDFDocument(data: data)?.findString("München", withOptions: []).count == 2, "one hit per page")
    }

    /// B1: a page with `/Rotate 90` and an Info Title and Author is rewritten, and keeps both; the line sits in its
    /// box on the page as shown.
    @Test func aRotatedPageWithATitleKeepsItsRotationAndTitle() throws {
        let source = TestPDF.makeRaw(
            pages: [.bar(keys: "/Rotate 90"), .bar()], info: "<< /Title (Rechnung 42) /Author (Muster GmbH) >>")

        let outcome = try layer(source, texts: ["Querformat Seite"])

        guard case .layered(let data) = outcome else {
            Issue.record("not layered: \(outcome)")
            return
        }
        let after = try #require(PDFDocument(data: data))
        #expect((0..<after.pageCount).map { after.page(at: $0)?.rotation } == [90, 0])
        #expect(after.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String == "Rechnung 42")
        #expect(after.documentAttributes?[PDFDocumentAttribute.authorAttribute] as? String == "Muster GmbH")
        #expect(after.documentAttributes?[TextLayer.markerKey] as? String == "1")
        // Where the line is on the rotated page as shown, normalised: inside its box.
        let page = try #require(after.page(at: 0))
        let selection = try #require(after.findString("Querformat", withOptions: []).first)
        let shown = selection.bounds(for: page).applying(page.transform(for: .cropBox))
        let size = CGSize(width: page.bounds(for: .cropBox).height, height: page.bounds(for: .cropBox).width)
        let center = CGPoint(x: shown.midX / size.width, y: shown.midY / size.height)
        let box = StubRecognizer.boxedLines(["Querformat Seite"])[0].boundingBox
        #expect(box.insetBy(dx: -0.02, dy: -0.02).contains(center), "the line at \(center), its box \(box)")
    }

    // MARK: - No rewrite: the stored file stays byte-identical

    /// One case of the B1 fixtures: the PDF, and why the layer keeps it.
    struct Kept: Sendable, CustomTestStringConvertible {
        let name: String
        let pdf: Data
        let reason: TextLayer.Kept
        var texts: [String] = TextLayerTests.lines

        var testDescription: String { name }
    }

    static let xml = "<rsm:CrossIndustryInvoice>factur-x probe</rsm:CrossIndustryInvoice>"

    static let keptCases: [Kept] = [
        // B1: an e-invoice (ZUGFeRD/Factur-X shape) with a recognised page 1 and a blank page 2.
        Kept(
            name: "e-invoice: /Names /EmbeddedFiles and /AF, a blank page",
            pdf: TestPDF.makeRaw(
                pages: [.bar(), .blank],
                catalogKeys: "/Names << /EmbeddedFiles << /Names [(factur-x.xml) 3 0 R] >> >> /AF [3 0 R]",
                objects: [
                    "<< /Type /Filespec /F (factur-x.xml) /UF (factur-x.xml) /AFRelationship /Alternative /EF << /F 4 0 R >> >>",
                    TestPDF.stream("/Type /EmbeddedFile /Subtype /text#2Fxml", xml),
                ], info: "<< /Title (Rechnung) >>"),
            reason: .catalogKey("AF")),
        Kept(
            name: "no recognised line",
            pdf: TestPDF.makeImageOnly(pages: [["Leer"], ["Leer"]]), reason: .noLines, texts: []),
        Kept(
            name: "/PageLabels",
            pdf: TestPDF.makeRaw(pages: [.bar()], catalogKeys: "/PageLabels << /Nums [0 << /S /r >>] >>"),
            reason: .catalogKey("PageLabels")),
        Kept(
            name: "XMP /Metadata",
            pdf: TestPDF.makeRaw(
                pages: [.bar()], catalogKeys: "/Metadata 3 0 R",
                objects: [
                    TestPDF.stream(
                        "/Type /Metadata /Subtype /XML",
                        "<x:xmpmeta xmlns:x=\"adobe:ns:meta/\"><pdfaid:part>3</pdfaid:part></x:xmpmeta>")
                ]),
            reason: .catalogKey("Metadata")),
        Kept(
            name: "/StructTreeRoot (tags)",
            pdf: TestPDF.makeRaw(
                pages: [.bar()], catalogKeys: "/StructTreeRoot 3 0 R",
                objects: ["<< /Type /StructTreeRoot /K [] >>"]),
            reason: .catalogKey("StructTreeRoot")),
        Kept(
            name: "/Outlines",
            pdf: TestPDF.makeRaw(
                pages: [.bar()], catalogKeys: "/Outlines 3 0 R", objects: ["<< /Type /Outlines /Count 0 >>"]),
            reason: .catalogKey("Outlines")),
        Kept(
            name: "/AcroForm",
            pdf: TestPDF.makeRaw(pages: [.bar()], catalogKeys: "/AcroForm << /Fields [] >>"),
            reason: .catalogKey("AcroForm")),
        Kept(
            name: "an annotation",
            pdf: TestPDF.makeRaw(
                pages: [.bar(keys: "/Annots [3 0 R]")],
                objects: [
                    "<< /Type /Annot /Subtype /Link /Rect [72 600 200 620] /Border [0 0 0] /A << /S /URI /URI (https://example.org) >> >>"
                ]),
            reason: .pageKey(page: 0, key: "Annots")),
        Kept(
            name: "a /TrimBox",
            pdf: TestPDF.makeRaw(pages: [.blank, .bar(keys: "/TrimBox [10 10 585 832]")]),
            reason: .pageKey(page: 1, key: "TrimBox")),
        Kept(
            name: "an owner password (encrypted, opens without one)",
            pdf: TestPDF.make(
                contents: [.image(["Geschützt"])],
                info: [kCGPDFContextOwnerPassword: "owner-secret", kCGPDFContextAllowsCopying: false]),
            reason: .encrypted),
        // P-m, R1-N1: a text page in a standard font without its program, beside a recognised page.
        Kept(
            name: "a non-embedded font",
            pdf: TestPDF.makeRaw(pages: [.standardFontText("Rechnung Nummer 2026-0042"), .bar()]),
            reason: .nonEmbeddedFont(page: 0)),
        // An Info entry the rewrite cannot carry exactly (B1 of PR #134).
        Kept(
            name: "a stream in the Info dictionary",
            pdf: TestPDF.makeRaw(
                pages: [.bar()], objects: [TestPDF.stream("", "Anhang")], info: "<< /Title (T) /Extra 3 0 R >>"),
            reason: .infoValue),
    ]

    @Test(arguments: keptCases)
    func aPDFOutsideTheRulesIsKeptByteIdentical(_ fixture: Kept) async throws {
        #expect(try layer(fixture.pdf, texts: fixture.texts) == .kept(fixture.reason))

        let store = try ProcessingStore()
        defer { store.remove() }
        let clock = TestClock()
        let id = try store.insert(device: deviceA, claimedAt: clock.now, pdf: fixture.pdf)

        let report = await store.queue(deviceA, stage: stage(fixture.texts), clock: clock).run()

        #expect(report.done == 1)
        #expect(report.layered == 0)
        #expect(try store.pdfData(of: id) == fixture.pdf, "the stored file changed")
        #expect(try store.fileSize(of: id) == 0, "the size is not touched")
        let text = try store.text(of: id)
        #expect(text.source == .vision)
        for line in fixture.texts { #expect(text.text?.contains(line) == true, "\(line) not in the stored text") }
    }

    /// B1: the embedded invoice XML is still in the stored file.
    @Test func theEInvoiceKeepsItsEmbeddedXML() async throws {
        let fixture = try #require(Self.keptCases.first)
        let store = try ProcessingStore()
        defer { store.remove() }
        let clock = TestClock()
        let id = try store.insert(device: deviceA, claimedAt: clock.now, pdf: fixture.pdf)

        _ = await store.queue(deviceA, stage: stage(), clock: clock).run()

        let stored = try #require(try store.pdfData(of: id))
        #expect(stored.range(of: Data(Self.xml.utf8)) != nil, "the embedded XML is gone")
    }

    /// N5: a layered PDF carries the marker and is never layered again, also when a page's own text stays below the
    /// text-page threshold (1–15 characters) and it is recognised again.
    @Test func aLayeredPDFIsNeverLayeredAgain() async throws {
        let source = TestPDF.makeImageOnly(pages: [["Nr. 42"]])
        let first = try await stage(["Nr. 42"]).process(pdfData: source) { _, _ in }
        let layered = try #require(first.layeredPDF)
        let page = try #require(PDFDocument(data: layered)?.page(at: 0))
        #expect(PageText.embeddedText(of: page) == nil, "below the threshold: recognised again")

        #expect(try layer(layered, texts: ["Nr. 42"]) == .kept(.marked))
        let again = try await stage(["Nr. 42"]).process(pdfData: layered) { _, _ in }
        #expect(again.layeredPDF == nil)
        #expect(again.text?.joined == "Nr. 42")
    }

    // MARK: - The guard

    /// The guard's Info compare: a rewrite whose Keywords became an array (what PDFKit writes) is rejected.
    @Test func theGuardRejectsAChangedInfoValue() throws {
        let source = TestPDF.makeRaw(pages: [.bar()], info: "<< /Keywords (a, b) >>")
        let document = try #require(PDFDocument(data: source))
        let textLayer = TextLayer { data in
            var info = (try? Self.info(source)).map(TextLayer.markedInfo) ?? [:]
            info[Array("Keywords".utf8)] = .array([.string(Array("a".utf8)), .string(Array("b".utf8))])
            return TextLayer.replacingInfo(in: data, with: info) ?? data
        }

        #expect(
            textLayer.apply(to: source, document: document, lines: [0: StubRecognizer.boxedLines(Self.lines)])
                == .kept(.guardFailed(.attributes)))
    }

    /// N-1 of PR #134's review B: a stage cancelled during the layer stops after the page it is on and throws.
    @Test func aCancelledStageStopsTheLayerAfterItsPage() async throws {
        let source = TestPDF.makeImageOnly(pages: [["a"], ["b"], ["c"]])
        let layerReports = ProgressCounter()
        let stage = stage()

        let run = Task {
            try await stage.process(pdfData: source) { completed, total in
                // The last page's own report, then one per page of the redraw: cancel at the redraw's first.
                guard completed == total else { return }
                layerReports.add()
                if layerReports.count == 2 { withUnsafeCurrentTask { $0?.cancel() } }
            }
        }

        await #expect(throws: CancellationError.self) { try await run.value }
        #expect(layerReports.count == 2, "the redraw went on after the cancel")
    }

    /// The guard's pixel compare: a rewrite whose page looks different is rejected, every other check holding. The
    /// difference is made in the test (the same rewrite, drawn from a copy whose bar sits 10 pt lower), because how a
    /// redraw changes a page is the platform's: a page in Helvetica without its program (P-m) rendered differently at
    /// 300 px on macOS at 48 pt but identically on the iOS simulator, and at 16 pt identically on both. That is why
    /// the font check comes before the rewrite (R1-N1).
    @Test func theGuardRejectsAPageThatLooksDifferent() throws {
        let source = TestPDF.makeRaw(pages: [.bar(), .bar()])
        let document = try #require(PDFDocument(data: source))
        let moved = TestPDF.makeRaw(pages: [TestPDF.RawPage(content: "0 0 0 rg 72 690 300 24 re f"), .bar()])
        let lines = [0: StubRecognizer.boxedLines(Self.lines), 1: StubRecognizer.boxedLines(Self.lines)]
        let textLayer = TextLayer { data in
            guard let original = PDFDocument(data: source), let drawn = TextLayer.cgDocument(moved) else { return data }
            return TextLayer.rewrite(drawn, document: original, lines: lines) {} ?? data
        }

        #expect(
            textLayer.apply(to: source, document: document, lines: lines) == .kept(.guardFailed(.pixels(page: 0))))
    }

    /// Each check of the guard, shown with a rewrite changed before it sees it.
    @Test(arguments: [
        ("rotation", TextLayer.GuardFailure.rotation(page: 0)),
        ("attributes", .attributes),
        ("pages", .pageCount),
        ("lines", .line(page: 0)),
    ])
    func theGuardRejectsAChangedRewrite(_ change: String, _ failure: TextLayer.GuardFailure) throws {
        let source = TestPDF.makeRaw(pages: [.bar(keys: "/Rotate 90"), .bar()], info: "<< /Title (Rechnung) >>")
        let document = try #require(PDFDocument(data: source))
        let textLayer = TextLayer { data in
            guard let rewritten = PDFDocument(data: data) else { return data }
            switch change {
            case "rotation": rewritten.page(at: 0)?.rotation = 0
            case "attributes": rewritten.documentAttributes = [TextLayer.markerKey: "1"]
            case "pages": rewritten.removePage(at: 1)
            default:
                return TestPDF.makeRaw(
                    pages: [.bar(keys: "/Rotate 90"), .bar()], info: "<< /Title (Rechnung) /DokumentumTextLayer (1) >>")
            }
            return rewritten.dataRepresentation() ?? data
        }
        let lines = [0: StubRecognizer.boxedLines(Self.lines), 1: StubRecognizer.boxedLines(Self.lines)]

        #expect(textLayer.apply(to: source, document: document, lines: lines) == .kept(.guardFailed(failure)))
    }

    /// The guard's check of each page's own text: a rewrite whose text page lost its text is rejected.
    @Test func theGuardRejectsARewriteThatLosesAPagesOwnText() throws {
        let source = TestPDF.make(contents: [.text(Self.born), .image(Self.lines)])
        let document = try #require(PDFDocument(data: source))
        // The same rewrite (rotation, attributes, marker from the source), drawn from a copy whose text page is blank.
        let withoutText = TestPDF.make(contents: [.blank, .image(Self.lines)])
        let textLayer = TextLayer { data in
            guard let original = PDFDocument(data: source), let drawn = TextLayer.cgDocument(withoutText) else {
                return data
            }
            return TextLayer.rewrite(drawn, document: original, lines: [1: StubRecognizer.boxedLines(Self.lines)]) {}
                ?? data
        }
        let lines = [1: StubRecognizer.boxedLines(Self.lines)]

        #expect(
            textLayer.apply(to: source, document: document, lines: lines) == .kept(.guardFailed(.sourceText(page: 0))))
    }

    /// A guard failure keeps the stored bytes and still writes the text.
    @Test func aGuardFailureKeepsTheFileAndWritesTheText() async throws {
        let store = try ProcessingStore()
        defer { store.remove() }
        let clock = TestClock()
        let source = TestPDF.makeImageOnly(pages: [Self.lines])
        let id = try store.insert(device: deviceA, claimedAt: clock.now, pdf: source)
        let broken = TextLayer { _ in TestPDF.makeImageOnly(pages: [["a"], ["b"]]) }

        let report = await store.queue(deviceA, stage: stage(textLayer: broken), clock: clock).run()

        #expect(report.done == 1)
        #expect(report.layered == 0)
        #expect(try store.pdfData(of: id) == source)
        #expect(try store.text(of: id).text == Self.lines.joined(separator: "\n"))
    }

    // MARK: - The result write

    /// The layered file replaces the stored one with its size; `contentHash` stays the original's, so importing the
    /// original bytes again is a duplicate.
    @Test func theLayeredFileIsStoredWithItsSizeAndTheOriginalStaysADuplicate() async throws {
        let store = try ProcessingStore()
        defer { store.remove() }
        let clock = TestClock()
        let source = TestPDF.makeImageOnly(pages: [Self.lines])
        let id = try store.insert(device: deviceA, claimedAt: clock.now, pdf: source)
        let hash = ContentHash.sha256(source)
        try store.edit(id) { document, _ in
            document.contentHash = hash
            document.fileSize = source.count
        }

        let report = await store.queue(deviceA, stage: stage(), clock: clock).run()

        #expect(report.done == 1)
        #expect(report.layered == 1)
        let stored = try #require(try store.pdfData(of: id))
        #expect(stored != source)
        #expect(try store.fileSize(of: id) == stored.count)
        #expect(PDFDocument(data: stored)?.findString("Fälligkeit", withOptions: []).count == 1)
        #expect(try store.contentHash(of: id) == hash)
        let again = await DocumentImporter(container: store.container, deviceID: deviceA).importFile(
            data: source, fileName: "Scan.pdf", contentType: .pdf)
        #expect(again == .duplicate(of: id, title: "Document", isTrashed: false))

        // N5 through the queue: processed again ("Try again", a re-queue), the file stays as it is.
        try store.edit(id) { document, _ in document.processingState = .pending }
        let next = await store.queue(deviceA, stage: stage(), clock: clock).run()
        #expect(next.done == 1)
        #expect(next.layered == 0)
        #expect(try store.pdfData(of: id) == stored)
    }

    /// An edit of the file row saved between the write's fetch and its check makes the write back off.
    @Test func anEditOfTheFileRowInTheWindowBacksOff() async throws {
        let store = try ProcessingStore()
        defer { store.remove() }
        let clock = TestClock()
        let source = TestPDF.makeImageOnly(pages: [Self.lines])
        let id = try store.insert(device: deviceA, claimedAt: clock.now, pdf: source)
        let edited = Mutex(false)
        let hooks = ProcessingQueue.Hooks(beforeCheck: { kind in
            guard kind == .result, !edited.withLock({ $0 }) else { return }
            edited.withLock { $0 = true }
            // Only the file row changes: the document and the text rows stay as the write read them.
            let context = ModelContext(store.container)
            let file = try #require(try ProcessingStore.fetch(id, in: context)?.file)
            file.createdAt = file.createdAt.addingTimeInterval(1)
            try context.save()
        })
        let queue = store.queue(deviceA, stage: stage(), clock: clock, hooks: hooks)

        let first = await queue.run()

        #expect(first.backedOff == 1)
        #expect(first.layered == 0)
        #expect(try store.pdfData(of: id) == source)
        #expect(try store.row(id).stateRaw == "pending")
        let next = await queue.run()
        #expect(next.layered == 1)
    }

    /// A takeover by another device between the load and the result write drops the result with its layer: the
    /// stored file stays the original.
    @Test func aTakeoverDuringTheStageDropsTheLayer() async throws {
        let store = try ProcessingStore()
        defer { store.remove() }
        let clock = TestClock()
        let source = TestPDF.makeImageOnly(pages: [Self.lines])
        let id = try store.insert(device: deviceA, claimedAt: clock.now, pdf: source)
        let recognition = Checkpoint()
        defer { recognition.release() }
        let stage = DocumentStage(recognizer: StubRecognizer.boxed(Self.lines, checkpoint: recognition))
        let queue = store.queue(deviceA, stage: stage, clock: clock)

        let run = Task { await queue.run() }
        await recognition.reached()
        try store.edit(id) { document, _ in
            document.processingDeviceID = deviceB
            document.processingClaimedAt = clock.now.addingTimeInterval(1)
        }
        recognition.release()
        let report = await run.value

        #expect(report.dropped == 1)
        #expect(report.layered == 0)
        #expect(try store.pdfData(of: id) == source)
        #expect(try store.row(id).deviceID == deviceB)
    }
}

/// Counts progress reports from any thread.
final class ProgressCounter: Sendable {
    private let value = Mutex(0)
    func add() { value.withLock { $0 += 1 } }
    var count: Int { value.withLock { $0 } }
}
