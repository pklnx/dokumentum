import DokumentumKit
import Foundation
import Testing

/// The share queue's format (plan of #4, part 4): the hand-over, the order, versions, unreadable items, attempts,
/// names that are never paths, removal. Every test works in a new temporary folder of its own; nothing here
/// touches an app group.
struct ShareQueueTests {
    /// A queue in a new temporary folder, removed after `body`. The folder's parent stands in for the group
    /// container, so a test can check that nothing is written next to `ShareQueue/`.
    private func withQueue(_ body: (ShareQueue, URL) throws -> Void) throws {
        let container = FileManager.default.temporaryDirectory
            .appending(path: "ShareQueueTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: container) }
        try body(ShareQueue(groupContainer: container), container)
    }

    private static let date = Date(timeIntervalSince1970: 1_800_000_000)

    private func names(in folder: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
    }

    /// Writes an entry into `Items/` by hand, as a broken or a newer writer would.
    private func writeItem(_ name: String, json: String?, in queue: ShareQueue) throws {
        let folder = queue.itemsFolder.appending(path: name, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("%PDF".utf8).write(to: folder.appending(path: "payload"))
        if let json { try Data(json.utf8).write(to: folder.appending(path: "item.json")) }
    }

    @Test func anItemMakesTheRoundTripWithItsBytesAndInfo() throws {
        try withQueue { queue, _ in
            let bytes = Data("%PDF-1.7 bytes".utf8)
            let id = try queue.add(
                data: bytes, originalFileName: "Rechnung.pdf", typeIdentifier: "com.adobe.pdf", createdAt: Self.date)
            let source = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).jpg")
            try Data("jpeg".utf8).write(to: source)
            defer { try? FileManager.default.removeItem(at: source) }
            let copied = try queue.add(
                copyingFileAt: source, originalFileName: "Foto.jpg", typeIdentifier: "public.jpeg",
                createdAt: Self.date.addingTimeInterval(1))

            let scan = queue.scan()

            #expect(scan.items.map(\.id) == [id, copied])
            let item = try #require(scan.items.first)
            #expect(item.info.version == ShareQueue.currentVersion)
            #expect(item.info.originalFileName == "Rechnung.pdf")
            #expect(item.info.typeIdentifier == "com.adobe.pdf")
            #expect(item.info.createdAt == Self.date)
            #expect(item.info.attempts == 0)
            #expect(try Data(contentsOf: queue.payloadURL(of: item)) == bytes)
            #expect(try Data(contentsOf: queue.payloadURL(of: scan.items[1])) == Data("jpeg".utf8))
            #expect(FileManager.default.fileExists(atPath: source.path), "the lent file stays where it was")
            #expect(names(in: queue.incomingFolder).isEmpty, "nothing is left in Incoming/")
            #expect(scan.movedToFailed.isEmpty && scan.newerVersion.isEmpty)
        }
    }

    @Test func anItemStillInIncomingIsInvisible() throws {
        try withQueue { queue, _ in
            // What the writer has before its last step, the rename: payload and item.json in Incoming/<UUID>/.
            let halfWritten = queue.incomingFolder.appending(path: UUID().uuidString, directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: halfWritten, withIntermediateDirectories: true)
            try Data("%PDF".utf8).write(to: halfWritten.appending(path: "payload"))
            try Data(#"{"version":1,"originalFileName":"a.pdf","typeIdentifier":"com.adobe.pdf","createdAt":0}"#.utf8)
                .write(to: halfWritten.appending(path: "item.json"))

            let scan = queue.scan()

            #expect(scan.items.isEmpty)
            #expect(scan.movedToFailed.isEmpty)
            #expect(names(in: queue.incomingFolder).count == 1, "the reader leaves Incoming/ alone")
        }
    }

    @Test func itemsComeOldestFirst() throws {
        try withQueue { queue, _ in
            let middle = try queue.add(
                data: Data("b".utf8), originalFileName: "b.pdf", typeIdentifier: "com.adobe.pdf",
                createdAt: Self.date.addingTimeInterval(60))
            let newest = try queue.add(
                data: Data("c".utf8), originalFileName: "c.pdf", typeIdentifier: "com.adobe.pdf",
                createdAt: Self.date.addingTimeInterval(120))
            let oldest = try queue.add(
                data: Data("a".utf8), originalFileName: "a.pdf", typeIdentifier: "com.adobe.pdf", createdAt: Self.date)

            #expect(queue.scan().items.map(\.id) == [oldest, middle, newest])
        }
    }

    @Test func anItemOfANewerVersionIsLeftAlone() throws {
        try withQueue { queue, _ in
            let id = UUID()
            try writeItem(
                id.uuidString,
                json: #"{"version":2,"originalFileName":"a.pdf","typeIdentifier":"com.adobe.pdf","createdAt":0}"#,
                in: queue)

            let scan = queue.scan()

            #expect(scan.items.isEmpty)
            #expect(scan.newerVersion == [id])
            #expect(scan.movedToFailed.isEmpty)
            #expect(names(in: queue.itemsFolder) == [id.uuidString], "it stays in Items/ for a newer app")
            #expect(names(in: queue.failedFolder).isEmpty)
        }
    }

    @Test(arguments: [
        ("not JSON", "{{{"),
        ("no version", #"{"originalFileName":"a.pdf","typeIdentifier":"com.adobe.pdf","createdAt":0}"#),
        ("version 0", #"{"version":0,"originalFileName":"a.pdf","typeIdentifier":"com.adobe.pdf","createdAt":0}"#),
        ("a field missing", #"{"version":1,"typeIdentifier":"com.adobe.pdf","createdAt":0}"#),
        ("a field of the wrong type", #"{"version":1,"originalFileName":7,"typeIdentifier":"x","createdAt":0}"#),
    ])
    func anUnreadableItemMovesToFailed(_ comment: String, json: String) throws {
        try withQueue { queue, _ in
            let id = UUID()
            try writeItem(id.uuidString, json: json, in: queue)
            let fine = try queue.add(data: Data("b".utf8), originalFileName: "b.pdf", typeIdentifier: "com.adobe.pdf")

            let scan = queue.scan()

            #expect(scan.items.map(\.id) == [fine], Comment(rawValue: comment))
            #expect(scan.movedToFailed == [id.uuidString])
            #expect(names(in: queue.failedFolder) == [id.uuidString])
            #expect(names(in: queue.itemsFolder) == [fine.uuidString])
            let payload = queue.failedFolder.appending(path: id.uuidString).appending(path: "payload")
            #expect(FileManager.default.fileExists(atPath: payload.path), "Failed/ keeps the bytes (PQ6)")
        }
    }

    @Test func anEntryWithoutItemJSONOrWithAForeignNameMovesToFailed() throws {
        try withQueue { queue, _ in
            let id = UUID()
            try writeItem(id.uuidString, json: nil, in: queue)
            try writeItem("not-an-identifier", json: nil, in: queue)

            let scan = queue.scan()

            #expect(scan.items.isEmpty)
            #expect(Set(scan.movedToFailed) == [id.uuidString, "not-an-identifier"])
            #expect(names(in: queue.itemsFolder).isEmpty)
        }
    }

    @Test func attemptsAreCountedInTheItemAndThreeLeaveNoneForFailed() throws {
        try withQueue { queue, _ in
            let id = try queue.add(
                data: Data("a".utf8), originalFileName: "a.pdf", typeIdentifier: "com.adobe.pdf", createdAt: Self.date)
            var item = try #require(queue.scan().items.first)
            for attempt in 1...ShareQueue.maxAttempts {
                #expect(!item.hasNoAttemptsLeft)
                item = try queue.recordAttempt(item)
                let reread = try #require(queue.scan().items.first)
                #expect(reread.info.attempts == attempt, "written to item.json")
                #expect(reread == item)
                #expect(reread.info.originalFileName == "a.pdf" && reread.info.createdAt == Self.date)
            }
            #expect(item.hasNoAttemptsLeft)

            try queue.moveToFailed(id)

            #expect(queue.scan().items.isEmpty)
            #expect(names(in: queue.failedFolder) == [id.uuidString])
        }
    }

    @Test func anAttemptOnAnItemThatIsGoneThrowsAndWritesNothing() throws {
        try withQueue { queue, _ in
            let id = try queue.add(data: Data("a".utf8), originalFileName: "a.pdf", typeIdentifier: "com.adobe.pdf")
            let item = try #require(queue.scan().items.first)
            try queue.remove(id)

            #expect(throws: (any Error).self) { try queue.recordAttempt(item) }
            #expect(names(in: queue.itemsFolder).isEmpty, "no folder is created again")
        }
    }

    @Test func aSecondFailedItemOfTheSameNameKeepsTheFirst() throws {
        try withQueue { queue, _ in
            let id = UUID()
            try writeItem(id.uuidString, json: "{", in: queue)
            _ = queue.scan()
            try writeItem(id.uuidString, json: "{", in: queue)
            _ = queue.scan()

            let failed = names(in: queue.failedFolder)
            #expect(failed.count == 2)
            #expect(failed.contains(id.uuidString))
        }
    }

    @Test(arguments: [
        ("../../x.pdf", "x.pdf", "x"),
        ("/etc/passwd", "passwd", "passwd"),
        ("..\\..\\Rechnung.pdf", "Rechnung.pdf", "Rechnung"),
        ("a\u{0}b\u{7}c\u{1B}.pdf", "abc.pdf", "abc"),
        ("  Vertrag\n.pdf ", "Vertrag.pdf", "Vertrag"),
        ("../", "..", ".."),
        ("", "", ""),
    ])
    func aSharedNameIsDataAndNeverLeavesTheQueue(shared: String, fileName: String, title: String) throws {
        try withQueue { queue, container in
            let id = try queue.add(data: Data("a".utf8), originalFileName: shared, typeIdentifier: "com.adobe.pdf")

            let item = try #require(queue.scan().items.first)

            #expect(item.info.originalFileName == shared, "stored as it came, as data")
            #expect(item.fileName == fileName)
            #expect(importTitle(fromFileName: item.fileName) == title)
            #expect(queue.payloadURL(of: item).lastPathComponent == "payload")
            #expect(names(in: container) == [ShareQueue.folderName], "nothing next to the queue")
            #expect(names(in: queue.root) == ["Incoming", "Items"])
            #expect(
                names(in: queue.itemsFolder.appending(path: id.uuidString)) == ["item.json", "payload"],
                "the item holds exactly its two files")
        }
    }

    @Test func aRemovedItemIsGoneItsNeighboursStayAndASecondRemovalIsNoError() throws {
        try withQueue { queue, _ in
            let ids = try (0..<3).map { index in
                try queue.add(
                    data: Data("\(index)".utf8), originalFileName: "\(index).pdf", typeIdentifier: "com.adobe.pdf",
                    createdAt: Self.date.addingTimeInterval(Double(index)))
            }

            #expect(try queue.remove(ids[1]))
            #expect(try !queue.remove(ids[1]), "removing it again is no error")

            #expect(queue.scan().items.map(\.id) == [ids[0], ids[2]])
            #expect(names(in: queue.itemsFolder) == [ids[0], ids[2]].map(\.uuidString).sorted())
        }
    }

    @Test func leftoversInIncomingOlderThanADayAreRemoved() throws {
        try withQueue { queue, _ in
            let now = Date()
            let (old, fresh) = (UUID().uuidString, UUID().uuidString)
            for name in [old, fresh] {
                try FileManager.default.createDirectory(
                    at: queue.incomingFolder.appending(path: name), withIntermediateDirectories: true)
            }
            try FileManager.default.setAttributes(
                [.modificationDate: now.addingTimeInterval(-ShareQueue.incomingMaxAge - 60)],
                ofItemAtPath: queue.incomingFolder.appending(path: old).path)
            try FileManager.default.setAttributes(
                [.modificationDate: now.addingTimeInterval(-ShareQueue.incomingMaxAge + 60)],
                ofItemAtPath: queue.incomingFolder.appending(path: fresh).path)

            #expect(queue.removeStaleIncoming(now: now) == 1)
            #expect(names(in: queue.incomingFolder) == [fresh])
        }
    }

    @Test func aMissingQueueIsAnEmptyOne() throws {
        try withQueue { queue, _ in
            let scan = queue.scan()
            #expect(scan.items.isEmpty && scan.movedToFailed.isEmpty && scan.newerVersion.isEmpty)
            #expect(queue.removeStaleIncoming() == 0)
            let removed = try queue.remove(UUID())
            #expect(!removed)
        }
    }
}
