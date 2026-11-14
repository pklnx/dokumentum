#if DEBUG
    import DokumentumCore
    import DokumentumKit
    import Foundation
    import SwiftData

    /// Writes the sample library (`FixtureCatalog`) into a store (plan of #3, part 2). Debug builds only.
    ///
    /// Two uses:
    /// - **`-UITestSeed`:** the in-memory store of UI tests and screenshots, which never syncs. Its records
    ///   keep the catalog's fixed `instanceID`s, so UI tests can address each one.
    /// - **"Add Sample Documents":** the debug command, into the open store, which may sync. Every record it
    ///   writes gets a fresh `instanceID` and `createdAt`, as #2 requires ("never copied": `keeperOrder` relies
    ///   on unique `instanceID`s); the catalog's fixed `5EED…` values are only the `id`. A second run adds
    ///   nothing: documents are matched by `id`. Metadata is reused by normalized name, tags by parent plus
    ///   normalized name, so the command creates no duplicate the repair would merge later. Two devices that
    ///   run it before their samples synced get documents with equal `id`s: #2's known, counted case.
    ///
    /// Each document is written with its `DocumentText` (at most `textLimit` bytes) and, unless it is the
    /// "still downloading" sample, its `DocumentFile`, and for a PDF its `DocumentThumbnail` as the importer makes it
    /// (#6, part 4), in one save, in the catalog's processing state (a processed sample with its text as `.pdfText`). Every PDF is generated (`SyntheticPDF`);
    /// nothing is read from disk.
    enum FixtureSeeder {
        enum InstanceIDs {
            /// The catalog's fixed values; only for the in-memory `-UITestSeed` store.
            case fixed
            /// New ones, with `createdAt` now: for any store that may sync.
            case fresh
        }

        /// The largest `extractedText` a sample gets, in UTF-8 bytes.
        static let textLimit = 1024

        /// Fills the in-memory store of a `-UITestSeed` launch, with the deadlines relative to `AppDay`'s today.
        static func seedForUITests(_ context: ModelContext, today: DeadlineDay = AppDay.today()) {
            do {
                try write(into: context, instanceIDs: .fixed, today: today)
            } catch {
                Log.store.error("Could not seed the sample documents: \(Log.code(of: error), privacy: .public)")
            }
        }

        /// The debug command: adds the samples that are not in the store yet. Returns how many documents it
        /// added.
        @discardableResult
        static func addSampleDocuments(
            to context: ModelContext, now: Date = Date(), today: DeadlineDay = AppDay.today()
        ) throws -> Int {
            try write(into: context, instanceIDs: .fresh, now: now, today: today)
        }

        /// - Parameter today: the day the samples' deadlines are relative to (#12, plan review B2).
        @discardableResult
        static func write(
            into context: ModelContext, instanceIDs: InstanceIDs, now: Date = Date(),
            today: DeadlineDay = AppDay.today()
        ) throws -> Int {
            let samples = FixtureCatalog.samples(today: today)
            let sampleIDs = samples.map(\.document.instanceID)
            let present = Set(
                try context.fetch(FetchDescriptor<Document>(predicate: #Predicate { sampleIDs.contains($0.id) }))
                    .map(\.id))
            var metadata = try MetadataIndex(context)
            var added = 0
            for sample in samples where !present.contains(sample.document.instanceID) {
                let values = sample.document
                let document = Document(
                    id: values.instanceID, title: values.title,
                    createdAt: instanceIDs == .fixed ? values.createdAt : now)
                if instanceIDs == .fixed { document.instanceID = values.instanceID }
                document.documentDate = values.documentDate
                document.isInbox = values.isInbox
                context.insert(document)
                document.correspondent = values.correspondent.map {
                    metadata.correspondent($0, instanceIDs: instanceIDs, now: now, in: context)
                }
                document.documentType = values.documentType.map {
                    metadata.documentType($0, instanceIDs: instanceIDs, now: now, in: context)
                }
                document.tags = FixtureCatalog.tags.filter { values.tagIDs.contains($0.instanceID) }.map {
                    metadata.tag($0, instanceIDs: instanceIDs, now: now, in: context)
                }
                let text = DocumentText(
                    documentID: document.id, extractedText: Self.text(of: sample), createdAt: document.createdAt)
                context.insert(text)
                document.text = text
                if let data = Self.fileData(of: sample) {
                    let file = DocumentFile(documentID: document.id, pdfData: data, createdAt: document.createdAt)
                    context.insert(file)
                    document.file = file
                    document.fileSize = data.count
                    if case .pdf = sample.file, let image = Thumbnail.make(fromPDF: data) {
                        let thumbnail = DocumentThumbnail(
                            documentID: document.id, imageData: image, createdAt: document.createdAt)
                        context.insert(thumbnail)
                        document.thumbnail = thumbnail
                    }
                }
                if let deadline = values.deadline {
                    document.deadlineDay = deadline.day.storedValue
                    document.deadlineLabel = deadline.label
                    document.deadlineSetAt = instanceIDs == .fixed ? deadline.setAt : now
                    document.deadlineDoneAt = deadline.doneAt.map { instanceIDs == .fixed ? $0 : now }
                }
                document.processingState = values.processingState
                if values.processingState == .done, !text.extractedText.isEmpty { document.textSource = .pdfText }
                if case .pdf(let pages) = sample.file { document.pageCount = pages.count }
                added += 1
            }
            if context.hasChanges { try context.save() }
            return added
        }

        /// The file's bytes: a generated PDF, the not-a-PDF bytes, or `nil` for the missing file.
        static func fileData(of sample: FixtureCatalog.Sample) -> Data? {
            switch sample.file {
            case .pdf(let pages): SyntheticPDF.make(pages: pages)
            case .notPDF: FixtureCatalog.notPDFData
            case .missing: nil
            }
        }

        /// The lines of the sample's pages, cut to `textLimit` bytes; empty for a sample without a PDF.
        static func text(of sample: FixtureCatalog.Sample) -> String {
            guard case .pdf(let pages) = sample.file else { return "" }
            var text = pages.map { $0.joined(separator: "\n") }.joined(separator: "\n\n")
            while text.utf8.count > textLimit { text.removeLast() }
            return text
        }

        /// The store's live metadata by merge key, and the records this run created.
        private struct MetadataIndex {
            var correspondents: [String: Correspondent] = [:]
            var documentTypes: [String: DocumentType] = [:]
            /// By parent `instanceID` (or none) and normalized name, the key of the repair's pass 2.
            var tags: [TagKey: DokumentumCore.Tag] = [:]
            /// The store tag for each catalog tag, so a child finds its parent.
            var tagsByCatalogID: [UUID: DokumentumCore.Tag] = [:]

            struct TagKey: Hashable {
                let parent: UUID?
                let name: String
            }

            init(_ context: ModelContext) throws {
                // The first live record in `keeperOrder` wins a name, as the repair's pass 2 would.
                for record in try context.fetch(FetchDescriptor<Correspondent>())
                    .sorted(by: { Self.precedes(($0.createdAt, $0.instanceID), ($1.createdAt, $1.instanceID)) })
                where record.isLive {
                    let key = MetadataName.normalized(record.name)
                    if correspondents[key] == nil { correspondents[key] = record }
                }
                for record in try context.fetch(FetchDescriptor<DocumentType>())
                    .sorted(by: { Self.precedes(($0.createdAt, $0.instanceID), ($1.createdAt, $1.instanceID)) })
                where record.isLive {
                    let key = MetadataName.normalized(record.name)
                    if documentTypes[key] == nil { documentTypes[key] = record }
                }
                for record in try context.fetch(FetchDescriptor<DokumentumCore.Tag>())
                    .sorted(by: { Self.precedes(($0.createdAt, $0.instanceID), ($1.createdAt, $1.instanceID)) })
                where record.isLive {
                    let key = TagKey(parent: record.parent?.instanceID, name: MetadataName.normalized(record.name))
                    if tags[key] == nil { tags[key] = record }
                }
            }

            /// `keeperOrder`: oldest `createdAt`, then the smaller `instanceID`.
            private static func precedes(_ lhs: (Date, UUID), _ rhs: (Date, UUID)) -> Bool {
                lhs.0 != rhs.0 ? lhs.0 < rhs.0 : lhs.1.uuidString < rhs.1.uuidString
            }

            mutating func correspondent(
                _ reference: LibraryDocument.Reference, instanceIDs: InstanceIDs, now: Date, in context: ModelContext
            ) -> Correspondent {
                let key = MetadataName.normalized(reference.name)
                if let existing = correspondents[key] { return existing }
                let record = Correspondent(name: reference.name, createdAt: now)
                record.id = reference.instanceID
                if instanceIDs == .fixed { record.instanceID = reference.instanceID }
                context.insert(record)
                correspondents[key] = record
                return record
            }

            mutating func documentType(
                _ reference: LibraryDocument.Reference, instanceIDs: InstanceIDs, now: Date, in context: ModelContext
            ) -> DocumentType {
                let key = MetadataName.normalized(reference.name)
                if let existing = documentTypes[key] { return existing }
                let record = DocumentType(name: reference.name, createdAt: now)
                record.id = reference.instanceID
                if instanceIDs == .fixed { record.instanceID = reference.instanceID }
                context.insert(record)
                documentTypes[key] = record
                return record
            }

            /// The catalog lists a parent before its children.
            mutating func tag(_ catalogTag: TagRecord, instanceIDs: InstanceIDs, now: Date, in context: ModelContext)
                -> DokumentumCore.Tag
            {
                if let known = tagsByCatalogID[catalogTag.instanceID] { return known }
                let parent = catalogTag.parentInstanceID.flatMap { parentID in
                    FixtureCatalog.tags.first { $0.instanceID == parentID }.map {
                        tag($0, instanceIDs: instanceIDs, now: now, in: context)
                    }
                }
                let key = TagKey(parent: parent?.instanceID, name: MetadataName.normalized(catalogTag.name))
                let record: DokumentumCore.Tag
                if let existing = tags[key] {
                    record = existing
                } else {
                    record = DokumentumCore.Tag(name: catalogTag.name, createdAt: now)
                    record.id = catalogTag.instanceID
                    if instanceIDs == .fixed { record.instanceID = catalogTag.instanceID }
                    context.insert(record)
                    record.parent = parent
                    tags[key] = record
                }
                tagsByCatalogID[catalogTag.instanceID] = record
                return record
            }
        }
    }
#endif
