import CoreData
import DokumentumCore
import DokumentumKit
import Foundation
import SwiftData
import Testing

@testable import Dokumentum

/// "Export state" of the Sync lab (plan of #31, T9, Revision 1 B2): canonical whatever the insertion order, every field
/// of the schema in it, dates at millisecond precision, large values only as length, hash and marker. In-memory stores.
@MainActor
struct SyncLabExportTests {
    /// Fixed records: two documents (one with file, thumbnail and text, tags, correspondent and type; one trashed),
    /// two tags with a parent, a tombstone correspondent, a type, and an unlinked text.
    struct Seed {
        static let base = Date(timeIntervalSince1970: 1_800_000_000)
        static let secret = "Geheimer Volltext syncwabcdef"

        /// Inserts the records in an order `generator` shuffles, then links and saves.
        static func insert(
            into container: ModelContainer, order generator: inout SplitMix64, dateOffset: TimeInterval = 0
        ) throws {
            let context = ModelContext(container)
            let date = base.addingTimeInterval(dateOffset)
            func id(_ n: Int) -> UUID { UUID(uuidString: String(format: "00000000-0000-0000-0000-%012ld", n))! }

            let first = Document(id: id(1), title: "Rechnung \"März\"\n2026", createdAt: date)
            first.instanceID = id(101)
            first.modifiedAt = date.addingTimeInterval(5)
            first.processingStateRaw = "done"
            first.processingDeviceID = "DEVICE-A"
            first.processingClaimedAt = date.addingTimeInterval(1)
            first.textSourceRaw = "vision"
            first.pageCount = 2
            first.fileSize = 3
            first.contentHash = "abc"
            first.originalFileName = "SyncLab-text-x.pdf"
            first.sourceRaw = "scan"
            let second = Document(id: id(2), title: "Vertrag", createdAt: date.addingTimeInterval(10))
            second.instanceID = id(102)
            second.deletedAt = date.addingTimeInterval(20)
            second.isInbox = false
            let file = DocumentFile(documentID: id(1), pdfData: Data([1, 2, 3]), createdAt: date)
            file.id = id(3)
            file.instanceID = id(103)
            let thumbnail = DocumentThumbnail(documentID: id(1), imageData: Data([9, 9]), createdAt: date)
            thumbnail.id = id(4)
            thumbnail.instanceID = id(104)
            let text = DocumentText(documentID: id(1), extractedText: secret, createdAt: date)
            text.id = id(5)
            text.instanceID = id(105)
            let orphan = DocumentText(documentID: id(1), extractedText: "", createdAt: date.addingTimeInterval(2))
            orphan.id = id(6)
            orphan.instanceID = id(106)
            let parent = DokumentumCore.Tag(name: "SyncLab-Y", createdAt: date)
            parent.id = id(7)
            parent.instanceID = id(107)
            let child = DokumentumCore.Tag(name: "SyncLab-X", createdAt: date)
            child.id = id(8)
            child.instanceID = id(108)
            let correspondent = Correspondent(name: "Stadtwerke", createdAt: date)
            correspondent.id = id(9)
            correspondent.instanceID = id(109)
            let tombstone = Correspondent(name: "stadtwerke", createdAt: date.addingTimeInterval(1))
            tombstone.id = id(10)
            tombstone.instanceID = id(110)
            tombstone.mergedIntoID = id(9)
            tombstone.mergedAt = date.addingTimeInterval(3)
            let type = DocumentType(name: "Rechnung", createdAt: date)
            type.id = id(11)
            type.instanceID = id(111)

            var records: [any PersistentModel] = [
                first, second, file, thumbnail, text, orphan, parent, child, correspondent, tombstone, type,
            ]
            records.shuffle(using: &generator)
            for record in records { context.insert(record) }
            var links: [() -> Void] = [
                { first.file = file }, { first.thumbnail = thumbnail }, { first.text = text },
                { first.tags = [child, parent] }, { first.correspondent = correspondent },
                { first.documentType = type }, { child.parent = parent }, { second.tags = [child] },
            ]
            links.shuffle(using: &generator)
            for link in links { link() }
            try context.save()
        }
    }

    private func dump(seed: UInt64, dateOffset: TimeInterval = 0) throws -> SyncLabExport.Dump {
        let container = try makeInMemoryContainer()
        var generator = SplitMix64(seed: seed)
        try Seed.insert(into: container, order: &generator, dateOffset: dateOffset)
        return try SyncLabExport.make(container: container, defaultsSuite: suite)
    }

    /// An empty defaults suite of the test's own: the device-local section reads nothing of the app's.
    private let suite = "DokumentumTests-SyncLabExport-\(UUID().uuidString)"

    @Test func theDumpIsTheSameForTwentyInsertionOrders() throws {
        let first = try dump(seed: 1)
        for seed in 2...20 {
            let other = try dump(seed: UInt64(seed))
            #expect(other.text == first.text, "order \(seed) gave another dump")
        }
        #expect(first.text.hasPrefix("dump sha256=\(first.hash)\n"))
        for name in SyncLabExport.entityNames {
            let hash = try #require(first.entityHashes[name])
            #expect(first.text.contains("entity \(name) records="), "\(name) has no header line")
            #expect(first.text.contains("sha256=\(hash)"))
        }
    }

    /// One changed field changes the dump's hash and only its entity's hash.
    @Test func oneChangedFieldChangesItsEntityHashOnly() throws {
        let container = try makeInMemoryContainer()
        var generator = SplitMix64(seed: 7)
        try Seed.insert(into: container, order: &generator)
        let before = try SyncLabExport.make(container: container, defaultsSuite: suite)
        let context = ModelContext(container)
        let tag = try #require(
            try context.fetch(FetchDescriptor<DokumentumCore.Tag>()).first { $0.name == "SyncLab-X" })
        tag.colorHex = "#000000"
        try context.save()
        let after = try SyncLabExport.make(container: container, defaultsSuite: suite)

        #expect(after.hash != before.hash)
        for name in SyncLabExport.entityNames {
            if name == "Tag" {
                #expect(after.entityHashes[name] != before.entityHashes[name])
            } else {
                #expect(after.entityHashes[name] == before.entityHashes[name], "\(name) changed")
            }
        }
    }

    /// Large values appear only as length and SHA-256 (the file also with its layer marker): never the text, the file
    /// or the thumbnail itself. The thumbnail's data is in the dump (B2).
    @Test func largeValuesAppearAsLengthAndHashOnly() throws {
        let dump = try dump(seed: 3)
        #expect(!dump.text.contains(Seed.secret))
        #expect(!dump.text.contains("syncwabcdef"))
        let textHash = SyncLabExport.sha256(Data(Seed.secret.utf8))
        #expect(dump.text.contains("DocumentText.extractedText=bytes=\(Seed.secret.utf8.count) sha256=\(textHash)"))
        let fileHash = SyncLabExport.sha256(Data([1, 2, 3]))
        #expect(dump.text.contains("DocumentFile.pdfData=bytes=3 sha256=\(fileHash) layer=no"))
        let thumbnailHash = SyncLabExport.sha256(Data([9, 9]))
        #expect(dump.text.contains("DocumentThumbnail.imageData=bytes=2 sha256=\(thumbnailHash)"))
    }

    /// Dates are whole milliseconds: a date and the same date plus 0.4 ms give one dump, plus 0.6 ms another (B2).
    @Test func datesAreComparedAtMillisecondPrecision() throws {
        let exact = try dump(seed: 4)
        let below = try dump(seed: 4, dateOffset: 0.0004)
        let above = try dump(seed: 4, dateOffset: 0.0006)
        #expect(below.text == exact.text)
        #expect(above.hash != exact.hash)
        #expect(SyncLabExport.milliseconds(Date(timeIntervalSince1970: 2)) == "2000")
        #expect(SyncLabExport.milliseconds(Date(timeIntervalSince1970: -2.0004)) == "-2000")
        #expect(SyncLabExport.milliseconds(nil) == "nil")
    }

    /// Every attribute and relationship of every entity of `DokumentumSchemaV1.models`, read from the model as
    /// `SchemaDump` reads it, has a line in the dump: a field added later cannot drop out of the comparison unnoticed.
    @Test func everyFieldOfTheSchemaIsInTheDump() throws {
        let dump = try dump(seed: 5)
        let model = try #require(NSManagedObjectModel.makeManagedObjectModel(for: DokumentumSchemaV1.models))
        var fields = 0
        for entity in model.entities {
            let name = try #require(entity.name)
            #expect(SyncLabExport.entityNames.contains(name), "\(name) is not dumped")
            for property in entity.propertiesByName.keys {
                fields += 1
                #expect(dump.text.contains("\n  \(name).\(property)="), "\(name).\(property) is missing")
            }
        }
        #expect(model.entities.count == SyncLabExport.entityNames.count)
        #expect(fields > 50)
    }

    /// Relationships appear as `instanceID`s, to-many sorted; strings are quoted with their escapes; the device-local
    /// section comes last and is not hashed.
    @Test func referencesStringsAndTheLocalSection() throws {
        let dump = try dump(seed: 6)
        #expect(
            dump.text.contains(
                "Document.tags=[00000000-0000-0000-0000-000000000107,00000000-0000-0000-0000-000000000108]"))
        #expect(dump.text.contains("Tag.parent=00000000-0000-0000-0000-000000000107"))
        #expect(dump.text.contains(#"Document.title="Rechnung \"März\"\n2026""#))
        #expect(dump.text.contains("Correspondent.mergedIntoID=00000000-0000-0000-0000-000000000009"))

        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: ProcessingRequeue.flagKey)
        let container = try makeInMemoryContainer()
        var generator = SplitMix64(seed: 6)
        try Seed.insert(into: container, order: &generator)
        let withFlag = try SyncLabExport.make(container: container, defaultsSuite: suite)
        #expect(withFlag.hash == dump.hash, "a device-local value changed the hash")
        #expect(withFlag.text.contains("device requeueDone=true"))
        let local = try #require(withFlag.text.range(of: "== Device-local values (not hashed)"))
        #expect(withFlag.text[local.upperBound...].contains("device requeueDone=true"))
    }

    /// The layer marker of a PDF that carries `DokumentumTextLayer` in its Info dictionary, whatever its value.
    @Test func theLayerMarkerIsRead() throws {
        #expect(!SyncLabExport.hasLayerMarker(SyntheticPDF.make(pages: [["Seite"]])))
        #expect(SyncLabExport.hasLayerMarker(Self.minimalPDF(info: "/\(TextLayer.markerKey) (1)")))
        #expect(!SyncLabExport.hasLayerMarker(Self.minimalPDF(info: "/Title (x)")))
        #expect(!SyncLabExport.hasLayerMarker(Data("not a pdf".utf8)))
    }

    /// A one-page PDF with the given Info dictionary entries, written by hand with a correct cross-reference table.
    static func minimalPDF(info: String) -> Data {
        let objects = [
            "<< /Type /Catalog /Pages 2 0 R >>", "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 100 100] >>", "<< \(info) >>",
        ]
        var text = "%PDF-1.4\n"
        var offsets: [Int] = []
        for (index, object) in objects.enumerated() {
            offsets.append(text.utf8.count)
            text += "\(index + 1) 0 obj\n\(object)\nendobj\n"
        }
        let xref = text.utf8.count
        text += "xref\n0 \(objects.count + 1)\n0000000000 65535 f \n"
        for offset in offsets { text += String(format: "%010ld 00000 n \n", offset) }
        text += "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R /Info 4 0 R >>\nstartxref\n\(xref)\n%%EOF\n"
        return Data(text.utf8)
    }
}
