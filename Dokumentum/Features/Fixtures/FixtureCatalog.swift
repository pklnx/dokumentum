#if DEBUG
    import DokumentumKit
    import Foundation

    /// The sample library of Debug builds: fictional names, generated PDFs, fixed IDs (the predecessor's
    /// `5EED…` pattern), so UI tests can address each document. Data, not UI text: nothing here is
    /// localized. Only in Debug builds; a Release build contains none of it (plan of #3, T3).
    ///
    /// The fixed `instanceID`s reach a store only in the in-memory `-UITestSeed` store, which never syncs.
    /// "Add Sample Documents" writes the same samples with fresh `instanceID`s and keeps the fixed values
    /// only as `id` (`FixtureSeeder`; plan of #3, Revision 1).
    enum FixtureCatalog {
        /// What a sample document's file is.
        enum File: Sendable, Equatable {
            /// A generated PDF with these pages of lines.
            case pdf(pages: [[String]])
            /// Bytes that are not a PDF: "This PDF cannot be shown".
            case notPDF
            /// No file yet: "Still downloading".
            case missing
        }

        struct Sample: Sendable {
            let document: LibraryDocument
            let file: File
        }

        /// `5EED<kind>-0000-4000-8000-<number>`: kind 0 documents, 1 tags, 2 correspondents, 3 types.
        static func id(kind: Int, _ number: Int) -> UUID {
            UUID(uuidString: String(format: "5EED%04d-0000-4000-8000-%012d", kind, number))!
        }

        static func documentID(_ number: Int) -> UUID { id(kind: 0, number) }

        // MARK: Metadata

        static let stadtwerke = LibraryDocument.Reference(instanceID: id(kind: 2, 1), name: "Stadtwerke Musterstadt")
        static let musterbank = LibraryDocument.Reference(instanceID: id(kind: 2, 2), name: "Musterbank AG")
        static let doctor = LibraryDocument.Reference(instanceID: id(kind: 2, 3), name: "Dr. Erika Beispiel")
        static let correspondents = [stadtwerke, musterbank, doctor]

        static let invoice = LibraryDocument.Reference(instanceID: id(kind: 3, 1), name: "Invoice")
        static let letter = LibraryDocument.Reference(instanceID: id(kind: 3, 2), name: "Letter")
        static let documentTypes = [invoice, letter]

        static let tax = TagRecord(instanceID: id(kind: 1, 1), parentInstanceID: nil, name: "Tax")
        static let important = TagRecord(instanceID: id(kind: 1, 2), parentInstanceID: nil, name: "Important")
        static let auto = TagRecord(instanceID: id(kind: 1, 3), parentInstanceID: nil, name: "Auto")
        /// Nested: Auto › Golf.
        static let golf = TagRecord(instanceID: id(kind: 1, 4), parentInstanceID: id(kind: 1, 3), name: "Golf")
        static let tags = [tax, important, auto, golf]

        // MARK: Documents

        /// Days before 2026-11-01, so the order is fixed and the newest comes first.
        private static func date(daysBefore days: Int) -> Date {
            // 2026-11-01 00:00 UTC.
            Date(timeIntervalSinceReferenceDate: 815_184_000 - Double(days) * 86_400)
        }

        /// `processing`: the queue's state (#6, P2); processed unless a sample shows another.
        private static func sample(
            _ number: Int, _ title: String, daysBefore days: Int, inbox: Bool,
            correspondent: LibraryDocument.Reference?, type: LibraryDocument.Reference?, tags: [TagRecord],
            file: File, processing: ProcessingState = .done
        ) -> Sample {
            let date = date(daysBefore: days)
            let document = LibraryDocument(
                instanceID: documentID(number), title: title, documentDate: date, createdAt: date, isInbox: inbox,
                correspondent: correspondent, documentType: type, tagIDs: Set(tags.map(\.instanceID)),
                fileState: file == .missing ? .missing : .present, processingState: processing)
            return Sample(document: document, file: file)
        }

        private static func letterPages(_ sender: String, _ subject: String, pages: Int = 1) -> [[String]] {
            (1...pages).map { page in
                [sender, subject, "Sample document, generated for Dokumentum.", "Page \(page) of \(pages)"]
            }
        }

        static let longTitle =
            "Annual statement of the supplementary pension insurance with a detailed overview of all contributions for 2025"

        static let samples: [Sample] = [
            sample(
                1, "Electricity bill October", daysBefore: 2, inbox: true, correspondent: stadtwerke, type: invoice,
                tags: [tax], file: .pdf(pages: letterPages(stadtwerke.name, "Electricity bill October"))),
            sample(
                2, "Medical invoice", daysBefore: 5, inbox: true, correspondent: doctor, type: invoice,
                tags: [tax, important], file: .pdf(pages: letterPages(doctor.name, "Medical invoice")),
                processing: .pending),
            sample(
                3, "Water bill", daysBefore: 9, inbox: false, correspondent: stadtwerke, type: invoice, tags: [tax],
                file: .missing),
            sample(
                4, "Account statement Q3", daysBefore: 14, inbox: false, correspondent: musterbank, type: letter,
                tags: [], file: .pdf(pages: letterPages(musterbank.name, "Account statement Q3", pages: 3))),
            sample(
                5, "", daysBefore: 20, inbox: true, correspondent: musterbank, type: letter, tags: [],
                file: .pdf(pages: letterPages(musterbank.name, "A letter without a title")), processing: .classify),
            sample(
                6, longTitle, daysBefore: 31, inbox: true, correspondent: musterbank, type: letter, tags: [important],
                file: .pdf(pages: letterPages(musterbank.name, "Annual statement 2025")), processing: .failed),
            sample(
                7, "Car insurance", daysBefore: 45, inbox: false, correspondent: musterbank, type: letter, tags: [auto],
                file: .pdf(pages: letterPages(musterbank.name, "Car insurance"))),
            sample(
                8, "Golf inspection", daysBefore: 60, inbox: false, correspondent: nil, type: invoice, tags: [golf],
                file: .pdf(pages: letterPages("Autohaus", "Golf inspection"))),
            sample(
                9, "Scanned receipt", daysBefore: 75, inbox: true, correspondent: nil, type: nil, tags: [],
                file: .notPDF, processing: .failed),
        ]

        static var snapshot: LibrarySnapshot {
            LibrarySnapshot(
                documents: samples.map(\.document), tags: tags, correspondents: correspondents,
                documentTypes: documentTypes)
        }

        /// The bytes of the sample that is not a PDF.
        static let notPDFData = Data("This is a plain text file, not a PDF.".utf8)
    }

    /// The sample library as a source without a store, for unit tests of `LibraryModel`: never
    /// changing. Each PDF is generated when it is opened, off the main actor.
    struct FixtureLibrarySource: LibrarySource {
        let changes = AsyncStream<Void> { _ in }

        @MainActor func snapshot() -> LibrarySnapshot { FixtureCatalog.snapshot }

        @concurrent
        func loadPDF(instanceID: UUID) async -> PDFLoadState {
            guard let sample = FixtureCatalog.samples.first(where: { $0.document.instanceID == instanceID }) else {
                return .noDocument
            }
            switch sample.file {
            case .pdf(let pages): return .data(SyntheticPDF.make(pages: pages))
            case .notPDF: return .data(FixtureCatalog.notPDFData)
            case .missing: return .noFile
            }
        }
    }
#endif
