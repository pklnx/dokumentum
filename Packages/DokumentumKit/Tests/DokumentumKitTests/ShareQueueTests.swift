import Foundation
import Testing

@testable import DokumentumKit

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

    // MARK: Round 2 of #85: links, the writer's hand-over, the cleanup's clock edges, names

    /// A file outside the queue and a symbolic link to it, as a sharing app could lend one.
    private func outsideFileAndLink(in container: URL) throws -> (file: URL, link: URL) {
        let outside = container.appending(path: "outside-secret.pdf")
        try Data("%PDF outside the queue".utf8).write(to: outside)
        let link = container.appending(path: "lent.pdf")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        return (outside, link)
    }

    /// Review A's `aLentSymlinkBecomesThePayload`, inverted: a lent link is refused and nothing is written.
    @Test func aLentSymbolicLinkIsRefusedAndNothingIsWritten() throws {
        try withQueue { queue, container in
            let (_, link) = try outsideFileAndLink(in: container)

            #expect(throws: ShareQueue.NotARegularFile.self) {
                try queue.add(copyingFileAt: link, originalFileName: "lent.pdf", typeIdentifier: "com.adobe.pdf")
            }

            #expect(queue.scan().items.isEmpty)
            #expect(names(in: queue.incomingFolder).isEmpty && names(in: queue.itemsFolder).isEmpty)
        }
    }

    @Test func aLentFolderIsRefused() throws {
        try withQueue { queue, container in
            let folder = container.appending(path: "folder.pdf", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

            #expect(throws: ShareQueue.NotARegularFile.self) {
                try queue.add(copyingFileAt: folder, originalFileName: "folder.pdf", typeIdentifier: "com.adobe.pdf")
            }
            #expect(queue.scan().items.isEmpty)
        }
    }

    @Test func aPayloadThatIsASymbolicLinkIsNotRead() throws {
        try withQueue { queue, container in
            let (_, link) = try outsideFileAndLink(in: container)
            try queue.add(
                data: Data("%PDF in the queue".utf8), originalFileName: "a.pdf", typeIdentifier: "com.adobe.pdf")
            let item = try #require(queue.scan().items.first)
            #expect(try queue.payload(of: item) == Data("%PDF in the queue".utf8), "a regular payload is read")
            try FileManager.default.removeItem(at: queue.payloadURL(of: item))
            try FileManager.default.createSymbolicLink(
                at: queue.payloadURL(of: item), withDestinationURL: link.resolvingSymlinksInPath())

            #expect(throws: ShareQueue.NotARegularFile.self) { try queue.payload(of: item) }
        }
    }

    @Test func anItemsEntryThatIsALinkToAFolderMovesToFailedAndItsTargetStays() throws {
        try withQueue { queue, container in
            let outside = container.appending(path: "outside", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
            try Data("%PDF".utf8).write(to: outside.appending(path: "payload"))
            try Data(#"{"version":1,"originalFileName":"a.pdf","typeIdentifier":"com.adobe.pdf","createdAt":0}"#.utf8)
                .write(to: outside.appending(path: "item.json"))
            try FileManager.default.createDirectory(at: queue.itemsFolder, withIntermediateDirectories: true)
            let id = UUID()
            try FileManager.default.createSymbolicLink(
                at: queue.itemsFolder.appending(path: id.uuidString), withDestinationURL: outside)

            let scan = queue.scan()

            #expect(scan.items.isEmpty)
            #expect(scan.movedToFailed == [id.uuidString])
            #expect(FileManager.default.fileExists(atPath: outside.appending(path: "payload").path))
        }
    }

    /// The writer's hand-over (review B, N2): the item is complete in `Incoming/` and invisible until the rename,
    /// then it is in `Items/` and `Incoming/` is empty.
    @Test func theWriterBuildsInIncomingAndHandsOverByOneRename() throws {
        try withQueue { queue, _ in
            var seen: URL?
            let id = try queue.add(
                data: Data("%PDF".utf8), originalFileName: "a.pdf", typeIdentifier: "com.adobe.pdf",
                createdAt: Self.date
            ) { building in
                seen = building
                #expect(
                    building.deletingLastPathComponent().standardizedFileURL == queue.incomingFolder.standardizedFileURL
                )
                #expect(names(in: building) == ["item.json", "payload"], "complete before the hand-over")
                #expect(queue.scan().items.isEmpty, "invisible before the hand-over")
            }

            #expect(seen?.lastPathComponent == id.uuidString)
            #expect(names(in: queue.incomingFolder).isEmpty)
            #expect(queue.scan().items.map(\.id) == [id])
        }
    }

    /// `item.json` is replaced, not written in place (review B, N2): a reader never sees half a file.
    @Test func anAttemptReplacesItemJSONAtomically() throws {
        try withQueue { queue, _ in
            let id = try queue.add(data: Data("a".utf8), originalFileName: "a.pdf", typeIdentifier: "com.adobe.pdf")
            let info = queue.itemsFolder.appending(path: id.uuidString).appending(path: "item.json")
            // The inode: a value type that differs between Foundation on Apple systems and on Linux.
            func fileNumber() throws -> UInt64? {
                let value = try FileManager.default.attributesOfItem(atPath: info.path)[.systemFileNumber]
                if let number = value as? NSNumber { return number.uint64Value }
                if let number = value as? UInt64 { return number }
                return (value as? Int).map(UInt64.init)
            }
            let before = try #require(try fileNumber())
            let item = try #require(queue.scan().items.first)

            _ = try queue.recordAttempt(item)

            let after = try #require(try fileNumber())
            #expect(after != before, "a new file renamed over the old one")
        }
    }

    /// Review A's `incomingCleanupAtTheClockEdges`: a leftover dated in the future stays (a clock set back), one a
    /// few seconds younger than a day stays, one a few seconds older than a day goes. No case sits on the exact
    /// boundary: file systems keep modification dates at different precisions (on Linux an "exactly one day"
    /// date came back a fraction older and was removed, PR #85 round 4).
    @Test func incomingCleanupAtTheClockEdges() throws {
        try withQueue { queue, _ in
            let now = Date()
            let (future, young, old) = (UUID().uuidString, UUID().uuidString, UUID().uuidString)
            for (name, age) in [
                (future, -3 * 86_400.0), (young, ShareQueue.incomingMaxAge - 5), (old, ShareQueue.incomingMaxAge + 5),
            ] {
                let url = queue.incomingFolder.appending(path: name)
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                try FileManager.default.setAttributes(
                    [.modificationDate: now.addingTimeInterval(-age)], ofItemAtPath: url.path)
            }

            #expect(queue.removeStaleIncoming(now: now) == 1)
            #expect(Set(names(in: queue.incomingFolder)) == [future, young])
        }
    }

    /// The share extension's name rule (`itemFileName`, deviation 5, reviews A-N3 and B-N3).
    @Test(
        arguments: [
            ("Rechnung.pdf", nil, "pdf", "Rechnung.pdf", "Rechnung"),
            ("scan.PDF", nil, "pdf", "scan.PDF", "scan"),
            ("Rechnung 2024.03", nil, "pdf", "Rechnung 2024.03.pdf", "Rechnung 2024.03"),
            ("scan.jpg", nil, "heic", "scan.jpg", "scan"),
            ("photo.png", nil, "jpeg", "photo.png", "photo"),
            ("notes.txt", nil, "pdf", "notes.txt.pdf", "notes.txt"),
            (nil, "lent.pdf", "pdf", "lent.pdf", "lent"),
            ("", "IMG_0001.HEIC", "heic", "IMG_0001.HEIC", "IMG_0001"),
            ("../../x", nil, "pdf", "x.pdf", "x"),
            (nil, nil, "pdf", "2027-01-15 08:00.pdf", "2027-01-15 08:00"),
            ("", "", "jpeg", "2027-01-15 08:00.jpeg", "2027-01-15 08:00"),
            (".pdf", nil, "pdf", "2027-01-15 08:00.pdf", "2027-01-15 08:00"),
            (nil, nil, nil, "2027-01-15 08:00", "2027-01-15 08:00"),
        ] as [(String?, String?, String?, String, String)])
    func theItemsNameKeepsATitle(
        suggested: String?, lent: String?, preferred: String?, fileName: String, title: String
    ) {
        let importable: Set<String> = ["pdf", "jpg", "jpeg", "png", "heic"]

        let name = ShareQueue.itemFileName(
            suggested: suggested, lentFileName: lent, preferredExtension: preferred, date: Self.date,
            timeZone: TimeZone(identifier: "UTC")!, isImportableExtension: importable.contains)

        #expect(name == fileName)
        #expect(importTitle(fromFileName: name) == title)
        #expect(!importTitle(fromFileName: name).isEmpty, "never an empty title")
    }

}
