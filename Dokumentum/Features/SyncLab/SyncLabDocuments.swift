#if DEBUG
    import DokumentumCore
    import DokumentumKit
    import Foundation
    import SwiftData

    /// The Sync lab's "Documents" section (plan of #31, Approach 3): every document, trashed ones included, as a light
    /// list, and one document's large values on demand. Both read in a fresh context off the main actor; the list never
    /// loads a file, thumbnail or text.
    enum SyncLabDocuments {
        /// One document as the list shows it.
        struct Row: Identifiable, Hashable, Sendable {
            let instanceID: UUID
            let title: String
            let originalFileName: String
            let state: String
            let claimDevice: String
            let claimedAt: Date?
            let textSource: String
            let pageCount: Int
            let fileSize: Int
            let isTrashed: Bool
            let isInbox: Bool
            let documentDate: Date
            let createdAt: Date
            let correspondent: String?
            let documentType: String?
            let tags: [String]

            var id: UUID { instanceID }

            var isLabDocument: Bool { SyncLabActions.isLabDocument(originalFileName: originalFileName) }

            /// "this device", or the claiming device's first 8 characters, "none" without a claim.
            func claim(thisDevice: String) -> String {
                if claimDevice.isEmpty { return "none" }
                return claimDevice == thisDevice ? "this device" : String(claimDevice.prefix(8))
            }
        }

        /// One document's large values, read on demand.
        struct Details: Sendable, Equatable {
            var text = "no text record"
            var file = "no file record"
            var thumbnail = "no thumbnail"
        }

        /// Every document, newest first; of copies sharing an `instanceID`, each.
        @concurrent
        static func rows(in container: ModelContainer) async throws -> [Row] {
            let context = ModelContext(container)
            let documents = try context.fetch(FetchDescriptor<Document>())
            return documents.map { document in
                Row(
                    instanceID: document.instanceID, title: document.title,
                    originalFileName: document.originalFileName, state: document.processingStateRaw,
                    claimDevice: document.processingDeviceID, claimedAt: document.processingClaimedAt,
                    textSource: document.textSourceRaw.isEmpty ? "none" : document.textSourceRaw,
                    pageCount: document.pageCount, fileSize: document.fileSize, isTrashed: document.deletedAt != nil,
                    isInbox: document.isInbox, documentDate: document.documentDate, createdAt: document.createdAt,
                    correspondent: document.correspondent?.name, documentType: document.documentType?.name,
                    tags: (document.tags ?? []).map(\.name).sorted())
            }
            .sorted { $0.createdAt > $1.createdAt }
        }

        /// The text as length and SHA-256 prefix, the file as length, SHA-256 prefix and layer marker, the thumbnail as
        /// length and SHA-256 prefix, of the oldest copy with `instanceID`.
        @concurrent
        static func details(of instanceID: UUID, in container: ModelContainer) async throws -> Details {
            let context = ModelContext(container)
            let documents = try context.fetch(
                FetchDescriptor<Document>(predicate: #Predicate { $0.instanceID == instanceID }))
            guard let document = documents.min(by: { $0.createdAt < $1.createdAt }) else { return Details() }
            var details = Details()
            if let text = document.text {
                let data = Data(text.extractedText.utf8)
                details.text = "\(data.count) bytes, sha256 \(SyncLabExport.sha256(data).prefix(12))"
            }
            if let file = document.file {
                if let data = file.pdfData {
                    let marker = SyncLabExport.hasLayerMarker(data) ? "layered" : "no layer"
                    details.file = "\(data.count) bytes, sha256 \(SyncLabExport.sha256(data).prefix(12)), \(marker)"
                } else {
                    details.file = "file record without data (still downloading)"
                }
            }
            if let data = document.thumbnail?.imageData {
                details.thumbnail = "\(data.count) bytes, sha256 \(SyncLabExport.sha256(data).prefix(12))"
            }
            return details
        }

        /// The live tags, correspondents and types by name (lab ones and others), for the pickers.
        struct Metadata: Sendable, Equatable {
            var tags: [Item] = []
            var correspondents: [Item] = []
            var types: [Item] = []

            struct Item: Identifiable, Hashable, Sendable {
                let instanceID: UUID
                let name: String
                let parent: String?

                var id: UUID { instanceID }
            }
        }

        @concurrent
        static func metadata(in container: ModelContainer) async throws -> Metadata {
            let context = ModelContext(container)
            let sort: (Metadata.Item, Metadata.Item) -> Bool = { $0.name < $1.name }
            return Metadata(
                tags: try context.fetch(FetchDescriptor<Tag>()).filter(\.isLive).map {
                    .init(instanceID: $0.instanceID, name: $0.name, parent: $0.parent?.name)
                }.sorted(by: sort),
                correspondents: try context.fetch(FetchDescriptor<Correspondent>()).filter(\.isLive).map {
                    .init(instanceID: $0.instanceID, name: $0.name, parent: nil)
                }.sorted(by: sort),
                types: try context.fetch(FetchDescriptor<DocumentType>()).filter(\.isLive).map {
                    .init(instanceID: $0.instanceID, name: $0.name, parent: nil)
                }.sorted(by: sort))
        }
    }
#endif
