#if DEBUG
    import CoreGraphics
    import CryptoKit
    import DokumentumCore
    import DokumentumKit
    import Foundation
    import SwiftData

    /// "Export state" (plan of #31, Approach 3, T9, Revision 1 B2 and note 5): a canonical text of every synced record
    /// of the store, so two devices are compared by one short hash and a difference is found per entity.
    ///
    /// - **First lines:** the SHA-256 of the dump, then one line per entity with its record count and SHA-256.
    /// - **Records** sorted by `instanceID` (copies sharing one by their text), one line per attribute and relationship
    ///   of `DokumentumSchemaV1.models` (`SyncLabExportTests` checks that none is missing), `modifiedAt`, `mergedAt`
    ///   and the claims included. Relationships as `instanceID`s (to-many sorted).
    /// - **Dates** as whole milliseconds since 1970 (UTC, rounded half away from zero): CloudKit keeps dates at
    ///   millisecond precision while the writing device keeps its full `Double`.
    /// - **Large values** never in full: the file as length, SHA-256 and the text layer marker, the thumbnail as length
    ///   and SHA-256, the text as UTF-8 length and SHA-256.
    /// - **This device's local values** (the device ID, the re-queue flag and backfill record, failure counters, claim
    ///   sightings) follow in a last section that no hash covers.
    ///
    /// Built off the main actor (`build`): a 20 MB file is hashed in C7.
    enum SyncLabExport {
        /// The dump and its hashes.
        struct Dump: Sendable, Equatable {
            /// The whole text, as copied and shared.
            let text: String
            /// The SHA-256 over the entity sections.
            let hash: String
            /// Each entity's SHA-256, by entity name.
            let entityHashes: [String: String]
        }

        /// The entities in dump order.
        static let entityNames = [
            "Document", "DocumentFile", "DocumentThumbnail", "DocumentText", "Tag", "Correspondent", "DocumentType",
        ]

        /// The dump of `container`, built off the main actor; local values from `defaultsSuite` (`nil`: the app's).
        @concurrent
        static func build(
            container: ModelContainer, defaultsSuite: String? = nil, dates: DateRounding = .nearest
        ) async throws -> Dump {
            try make(container: container, defaultsSuite: defaultsSuite, dates: dates)
        }

        /// How dates become whole milliseconds. `nearest` (the default) rounds half away from zero; `towardZero`
        /// truncates, for the case that CloudKit truncates and the two devices' dumps differ by 1 ms (review B, N6 of
        /// PR #155; `sync.md`, step 0). Both devices must use the same; the first line names it.
        enum DateRounding: String, CaseIterable, Sendable {
            case nearest
            case towardZero

            func string(_ date: Date?) -> String {
                guard let date else { return "nil" }
                let rule: FloatingPointRoundingRule = self == .nearest ? .toNearestOrAwayFromZero : .towardZero
                return String(Int64((date.timeIntervalSince1970 * 1000).rounded(rule)))
            }
        }

        /// The dump of `container`, in a fresh context. Synchronous: callers off the main actor only (`build`).
        static func make(
            container: ModelContainer, defaultsSuite: String? = nil, dates: DateRounding = .nearest
        ) throws -> Dump {
            let context = ModelContext(container)
            var sections: [(name: String, records: Int, text: String)] = []
            sections.append(
                section("Document", try context.fetch(FetchDescriptor<Document>()).map { lines($0, dates) }))
            sections.append(
                section("DocumentFile", try context.fetch(FetchDescriptor<DocumentFile>()).map { lines($0, dates) }))
            sections.append(
                section(
                    "DocumentThumbnail",
                    try context.fetch(FetchDescriptor<DocumentThumbnail>()).map { lines($0, dates) }))
            sections.append(
                section("DocumentText", try context.fetch(FetchDescriptor<DocumentText>()).map { lines($0, dates) }))
            sections.append(section("Tag", try context.fetch(FetchDescriptor<Tag>()).map { lines($0, dates) }))
            sections.append(
                section("Correspondent", try context.fetch(FetchDescriptor<Correspondent>()).map { lines($0, dates) }))
            sections.append(
                section("DocumentType", try context.fetch(FetchDescriptor<DocumentType>()).map { lines($0, dates) }))

            var entityHashes: [String: String] = [:]
            var hasher = SHA256()
            var header: [String] = []
            for section in sections {
                let hash = sha256(Data(section.text.utf8))
                entityHashes[section.name] = hash
                hasher.update(data: Data(section.text.utf8))
                header.append("entity \(section.name) records=\(section.records) sha256=\(hash)")
            }
            let hash = hex(hasher.finalize())
            var text = "dump sha256=\(hash) dates=\(dates.rawValue)\n" + header.joined(separator: "\n") + "\n\n"
            for section in sections { text += section.text }
            text += "== Device-local values (not hashed)\n" + localLines(defaultsSuite: defaultsSuite).joined() + "\n"
            return Dump(text: text, hash: hash, entityHashes: entityHashes)
        }

        // MARK: Records

        /// One record: its `instanceID` and its lines.
        private struct Record {
            let instanceID: String
            let lines: [String]
        }

        private static func section(_ name: String, _ records: [Record]) -> (name: String, records: Int, text: String) {
            let sorted = records.sorted { lhs, rhs in
                lhs.instanceID != rhs.instanceID
                    ? lhs.instanceID < rhs.instanceID : lhs.lines.joined() < rhs.lines.joined()
            }
            var text = "== \(name)\n"
            for record in sorted {
                text += "record \(record.instanceID)\n"
                for line in record.lines { text += "  \(line)\n" }
            }
            return (name, records.count, text)
        }

        private static func lines(_ document: Document, _ ms: DateRounding) -> Record {
            let e = "Document"
            return Record(
                instanceID: document.instanceID.uuidString,
                lines: [
                    "\(e).id=\(document.id.uuidString)",
                    "\(e).instanceID=\(document.instanceID.uuidString)",
                    "\(e).title=\(quoted(document.title))",
                    "\(e).createdAt=\(ms.string(document.createdAt))",
                    "\(e).modifiedAt=\(ms.string(document.modifiedAt))",
                    "\(e).documentDate=\(ms.string(document.documentDate))",
                    "\(e).isInbox=\(document.isInbox)",
                    "\(e).pageCount=\(document.pageCount)",
                    "\(e).fileSize=\(document.fileSize)",
                    "\(e).textSourceRaw=\(quoted(document.textSourceRaw))",
                    "\(e).processingStateRaw=\(quoted(document.processingStateRaw))",
                    "\(e).processingDeviceID=\(quoted(document.processingDeviceID))",
                    "\(e).processingClaimedAt=\(ms.string(document.processingClaimedAt))",
                    "\(e).contentHash=\(quoted(document.contentHash))",
                    "\(e).originalFileName=\(quoted(document.originalFileName))",
                    "\(e).sourceRaw=\(quoted(document.sourceRaw))",
                    "\(e).deletedAt=\(ms.string(document.deletedAt))",
                    "\(e).correspondent=\(reference(document.correspondent?.instanceID))",
                    "\(e).documentType=\(reference(document.documentType?.instanceID))",
                    "\(e).tags=\(references(document.tags?.map(\.instanceID)))",
                    "\(e).file=\(reference(document.file?.instanceID))",
                    "\(e).thumbnail=\(reference(document.thumbnail?.instanceID))",
                    "\(e).text=\(reference(document.text?.instanceID))",
                ])
        }

        private static func lines(_ file: DocumentFile, _ ms: DateRounding) -> Record {
            let e = "DocumentFile"
            return Record(
                instanceID: file.instanceID.uuidString,
                lines: [
                    "\(e).id=\(file.id.uuidString)",
                    "\(e).instanceID=\(file.instanceID.uuidString)",
                    "\(e).createdAt=\(ms.string(file.createdAt))",
                    "\(e).documentID=\(reference(file.documentID))",
                    "\(e).pdfData=\(blob(file.pdfData, marker: true))",
                    "\(e).document=\(reference(file.document?.instanceID))",
                ])
        }

        private static func lines(_ thumbnail: DocumentThumbnail, _ ms: DateRounding) -> Record {
            let e = "DocumentThumbnail"
            return Record(
                instanceID: thumbnail.instanceID.uuidString,
                lines: [
                    "\(e).id=\(thumbnail.id.uuidString)",
                    "\(e).instanceID=\(thumbnail.instanceID.uuidString)",
                    "\(e).createdAt=\(ms.string(thumbnail.createdAt))",
                    "\(e).documentID=\(reference(thumbnail.documentID))",
                    "\(e).imageData=\(blob(thumbnail.imageData, marker: false))",
                    "\(e).document=\(reference(thumbnail.document?.instanceID))",
                ])
        }

        private static func lines(_ text: DocumentText, _ ms: DateRounding) -> Record {
            let e = "DocumentText"
            let value = Data(text.extractedText.utf8)
            return Record(
                instanceID: text.instanceID.uuidString,
                lines: [
                    "\(e).id=\(text.id.uuidString)",
                    "\(e).instanceID=\(text.instanceID.uuidString)",
                    "\(e).createdAt=\(ms.string(text.createdAt))",
                    "\(e).documentID=\(reference(text.documentID))",
                    "\(e).extractedText=bytes=\(value.count) sha256=\(sha256(value))",
                    "\(e).document=\(reference(text.document?.instanceID))",
                ])
        }

        private static func lines(_ tag: Tag, _ ms: DateRounding) -> Record {
            let e = "Tag"
            return Record(
                instanceID: tag.instanceID.uuidString,
                lines: [
                    "\(e).id=\(tag.id.uuidString)",
                    "\(e).instanceID=\(tag.instanceID.uuidString)",
                    "\(e).name=\(quoted(tag.name))",
                    "\(e).colorHex=\(quoted(tag.colorHex))",
                    "\(e).createdAt=\(ms.string(tag.createdAt))",
                    "\(e).mergedIntoID=\(reference(tag.mergedIntoID))",
                    "\(e).mergedAt=\(ms.string(tag.mergedAt))",
                    "\(e).parent=\(reference(tag.parent?.instanceID))",
                    "\(e).children=\(references(tag.children?.map(\.instanceID)))",
                    "\(e).documents=\(references(tag.documents?.map(\.instanceID)))",
                ])
        }

        private static func lines(_ correspondent: Correspondent, _ ms: DateRounding) -> Record {
            let e = "Correspondent"
            return Record(
                instanceID: correspondent.instanceID.uuidString,
                lines: [
                    "\(e).id=\(correspondent.id.uuidString)",
                    "\(e).instanceID=\(correspondent.instanceID.uuidString)",
                    "\(e).name=\(quoted(correspondent.name))",
                    "\(e).createdAt=\(ms.string(correspondent.createdAt))",
                    "\(e).mergedIntoID=\(reference(correspondent.mergedIntoID))",
                    "\(e).mergedAt=\(ms.string(correspondent.mergedAt))",
                    "\(e).documents=\(references(correspondent.documents?.map(\.instanceID)))",
                ])
        }

        private static func lines(_ type: DocumentType, _ ms: DateRounding) -> Record {
            let e = "DocumentType"
            return Record(
                instanceID: type.instanceID.uuidString,
                lines: [
                    "\(e).id=\(type.id.uuidString)",
                    "\(e).instanceID=\(type.instanceID.uuidString)",
                    "\(e).name=\(quoted(type.name))",
                    "\(e).createdAt=\(ms.string(type.createdAt))",
                    "\(e).mergedIntoID=\(reference(type.mergedIntoID))",
                    "\(e).mergedAt=\(ms.string(type.mergedAt))",
                    "\(e).documents=\(references(type.documents?.map(\.instanceID)))",
                ])
        }

        // MARK: Values

        /// Whole milliseconds since 1970, rounded half away from zero; `nil` for none.
        static func milliseconds(_ date: Date?) -> String {
            DateRounding.nearest.string(date)
        }

        static func quoted(_ string: String) -> String {
            var result = "\""
            for scalar in string.unicodeScalars {
                switch scalar {
                case "\"": result += "\\\""
                case "\\": result += "\\\\"
                case "\n": result += "\\n"
                case "\r": result += "\\r"
                case "\t": result += "\\t"
                default:
                    if scalar.value < 0x20 {
                        result += String(format: "\\u%04x", scalar.value)
                    } else {
                        result.unicodeScalars.append(scalar)
                    }
                }
            }
            return result + "\""
        }

        private static func reference(_ id: UUID?) -> String {
            id?.uuidString ?? "nil"
        }

        private static func references(_ ids: [UUID]?) -> String {
            "[" + (ids ?? []).map(\.uuidString).sorted().joined(separator: ",") + "]"
        }

        /// Length and SHA-256 of `data`, and with `marker` whether the PDF carries the text layer marker.
        static func blob(_ data: Data?, marker: Bool) -> String {
            guard let data else { return "nil" }
            var text = "bytes=\(data.count) sha256=\(sha256(data))"
            if marker { text += " layer=\(hasLayerMarker(data) ? "yes" : "no")" }
            return text
        }

        /// Whether the PDF's Info dictionary has `TextLayer.markerKey` (`DokumentumTextLayer`), whatever its value.
        static func hasLayerMarker(_ data: Data) -> Bool {
            guard let provider = CGDataProvider(data: data as CFData), let pdf = CGPDFDocument(provider),
                let info = pdf.info
            else { return false }
            var object: CGPDFObjectRef?
            return TextLayer.markerKey.withCString { CGPDFDictionaryGetObject(info, $0, &object) }
        }

        static func sha256(_ data: Data) -> String {
            hex(SHA256.hash(data: data))
        }

        private static func hex(_ digest: SHA256.Digest) -> String {
            digest.map { String(format: "%02x", $0) }.joined()
        }

        // MARK: Device-local values

        private static func localLines(defaultsSuite: String?) -> [String] {
            let defaults = defaultsSuite.flatMap(UserDefaults.init(suiteName:)) ?? .standard
            let requeue = ProcessingRequeue(defaultsSuite: defaultsSuite)
            var lines = [
                "device processingDeviceID=\(quoted(defaults.string(forKey: DeviceIdentity.defaultsKey) ?? ""))\n",
                "device requeueDone=\(requeue.isDone)\n",
                "device thumbnailBackfill=\(references(Array(requeue.thumbnailBackfill)))\n",
            ]
            for key in [ProcessingFailures.defaultsKey, ProcessingFailures.classificationDefaultsKey] {
                let failures = ProcessingFailures(defaultsSuite: defaultsSuite, key: key)
                for document in failures.documents.sorted(by: { $0.uuidString < $1.uuidString }) {
                    let entry = failures.entry(for: document)
                    lines.append(
                        "\(key) \(document.uuidString) attempts=\(entry?.attempts ?? 0) "
                            + "last=\(milliseconds(entry?.lastAttemptAt))\n")
                }
            }
            let sightings = ClaimSightings(defaultsSuite: defaultsSuite)
            for document in sightings.documents.sorted(by: { $0.uuidString < $1.uuidString }) {
                guard let sighting = sightings.sighting(of: document) else { continue }
                lines.append(
                    "sighting \(document.uuidString) device=\(quoted(sighting.deviceID)) "
                        + "claimedAt=\(milliseconds(sighting.claimedAt)) seenAt=\(milliseconds(sighting.seenAt))\n")
            }
            return lines
        }
    }
#endif
