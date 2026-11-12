import CoreGraphics
import DokumentumCoreTestSupport
import DokumentumKit
import DokumentumTestSupport
import Foundation
import SwiftData
import Testing

@testable import DokumentumCore

/// A list row's thumbnail (#6, part 4): `ThumbnailLoader` decodes one document's thumbnail by key, scaled for a row,
/// keeps the images it decoded and nothing for a document without one, so a thumbnail that arrives later is found.
struct ThumbnailLoaderTests {
    /// A document imported with its thumbnail.
    private func imported(into container: ModelContainer, pages: [String] = ["Seite"]) async throws -> UUID {
        let outcome = await DocumentImporter(container: container, deviceID: deviceA)
            .importFile(data: TestPDF.make(pages: pages), fileName: "\(UUID().uuidString).pdf")
        guard case .imported(let id) = outcome else { throw ImportFailed(outcome: outcome) }
        return id
    }

    private struct ImportFailed: Error {
        let outcome: ImportOutcome
    }

    @Test func itDecodesTheThumbnailScaledForARow() async throws {
        let container = try TestSupport.makeContainer()
        let id = try await imported(into: container)
        let loader = ThumbnailLoader(container: container)

        let image = try #require(await loader.image(for: id))

        #expect(image.height == ThumbnailLoader.pixelSize, "A4 portrait: the long side is the height")
        #expect(image.width < image.height)
        #expect(loader.keptCount == 1)
    }

    /// No thumbnail yet (an import whose render failed, or one still arriving): `nil`, nothing kept, and once one is
    /// linked the next load finds it.
    @Test func aDocumentWithoutAThumbnailIsLookedForAgain() async throws {
        let store = try ProcessingStore()
        defer { store.remove() }
        let id = try store.insert(stateRaw: "done")
        let loader = ThumbnailLoader(container: store.container)

        #expect(await loader.image(for: id) == nil)
        #expect(loader.keptCount == 0)
        #expect(await loader.image(for: UUID()) == nil, "no such document")

        let jpeg = try #require(Thumbnail.make(fromPDF: TestPDF.make(pages: ["Seite"])))
        try store.edit(id) { document, context in
            let thumbnail = DocumentThumbnail(documentID: document.id, imageData: jpeg)
            context.insert(thumbnail)
            document.thumbnail = thumbnail
        }
        #expect(await loader.image(for: id) != nil)
        #expect(loader.keptCount == 1)
    }

    /// Data that does not decode gives `nil`, not a crash.
    @Test func dataThatDoesNotDecodeGivesNothing() async throws {
        let store = try ProcessingStore()
        defer { store.remove() }
        let id = try store.insert(stateRaw: "done", thumbnail: true)
        #expect(await ThumbnailLoader(container: store.container).image(for: id) == nil)
    }

    /// A kept image is served without a read; the oldest goes beyond the limit.
    @Test func keptImagesAreServedAndTheOldestGoesBeyondTheLimit() async throws {
        let store = try ProcessingStore()
        defer { store.remove() }
        let first = try await imported(into: store.container, pages: ["Eins"])
        let second = try await imported(into: store.container, pages: ["Zwei"])
        let third = try await imported(into: store.container, pages: ["Drei"])
        let loader = ThumbnailLoader(container: store.container, cacheLimit: 2)
        let kept = try #require(await loader.image(for: first))
        // The store's copy goes: the kept image is still served.
        try store.edit(first) { document, context in
            if let thumbnail = document.thumbnail { context.delete(thumbnail) }
        }
        #expect(await loader.image(for: first) === kept)

        _ = await loader.image(for: second)
        _ = await loader.image(for: third)

        #expect(loader.keptCount == 2)
        #expect(await loader.image(for: first) == nil, "dropped, and read again: the store has none now")
    }
}

/// What the loader reads: one document by key and its thumbnail by key, never the file or the text. Runs under
/// `swift test` only (`SQLLog.isReadable`).
struct ThumbnailLoaderSQLTests {
    @Test(.enabled(if: SQLLog.isReadable, "Core Data logs no SQL in the xctest runner (measured on #29)"))
    func oneThumbnailIsReadByKeyAndNoOtherBlob() throws {
        let store = try ProcessingStore()
        defer { store.remove() }
        var target: UUID?
        for index in 0..<3 {
            let id = try store.insert(title: "Document \(index)", stateRaw: "done", thumbnail: true)
            try store.edit(id) { document, _ in document.text?.extractedText = "text \(index)" }
            target = target ?? id
        }
        let id = try #require(target)

        let recording = try SQLLog.Recording()
        let data = ThumbnailLoader.data(for: id, in: store.container)
        let statements = try recording.statements()

        #expect(data?.count == 100)
        let documentReads = statements.filter { $0.contains("FROM ZDOCUMENT t0") }
        #expect(documentReads.count == 1, "\(statements)")
        #expect(documentReads.allSatisfy { $0.contains("ZINSTANCEID") }, "not by instanceID: \(documentReads)")
        let thumbnailReads = statements.filter { SQLLog.statement($0, names: "ZDOCUMENTTHUMBNAIL") }
        #expect(thumbnailReads.count == 1, "\(thumbnailReads)")
        #expect(thumbnailReads.allSatisfy { $0.contains("WHERE  t0.Z_PK IN  (?)") }, "not by key: \(thumbnailReads)")
        for statement in statements {
            #expect(!SQLLog.statement(statement, names: "ZDOCUMENTFILE"), "\(statement)")
            #expect(!SQLLog.statement(statement, names: "ZDOCUMENTTEXT"), "\(statement)")
        }
    }
}
