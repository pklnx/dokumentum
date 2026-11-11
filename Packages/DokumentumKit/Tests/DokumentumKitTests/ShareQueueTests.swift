import Foundation
import Testing

@testable import DokumentumKit

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#elseif canImport(Musl)
    import Musl
#endif

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

    // MARK: #87, part 1: every file is opened once, never through a link

    /// Runs `body` and returns the code of the `POSIXError` it throws, `nil` for any other outcome.
    private func posixCode(_ body: () throws -> Void) -> POSIXErrorCode? {
        do {
            try body()
            return nil
        } catch let error as POSIXError {
            return error.code
        } catch {
            return nil
        }
    }

    /// Replaces the folder or file at `url` with a symbolic link to `target`, keeping the original aside.
    private func swapForALink(_ url: URL, to target: URL, keepingIn container: URL) throws {
        try FileManager.default.moveItem(at: url, to: container.appending(path: "moved-away-\(UUID().uuidString)"))
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: target)
    }

    /// K1: an `item.json` that is a link to JSON outside the queue is never read; the item moves to `Failed/`.
    @Test func aLinkedItemJSONMovesToFailedAndIsNotRead() throws {
        try withQueue { queue, container in
            let outside = container.appending(path: "outside.json")
            let outsideJSON = Data(
                #"{"version":1,"originalFileName":"from-outside.pdf","typeIdentifier":"com.adobe.pdf","createdAt":0}"#
                    .utf8)
            try outsideJSON.write(to: outside)
            let id = try queue.add(
                data: Data("%PDF".utf8), originalFileName: "inside.pdf", typeIdentifier: "com.adobe.pdf")
            let info = queue.itemsFolder.appending(path: id.uuidString).appending(path: "item.json")
            try swapForALink(info, to: outside, keepingIn: container)

            let scan = queue.scan()

            #expect(scan.items.isEmpty, "the outside JSON is not read: \(scan.items.map(\.info.originalFileName))")
            #expect(scan.movedToFailed == [id.uuidString])
            #expect(names(in: queue.failedFolder) == [id.uuidString])
            #expect(try Data(contentsOf: outside) == outsideJSON, "the outside file stays as it was")
        }
    }

    /// K2: a payload swapped for a link after the reader opened it: the reader keeps reading the file it opened.
    @Test func aPayloadSwappedForALinkAfterItWasOpenedIsNotFollowed() throws {
        try withQueue { queue, container in
            let outside = container.appending(path: "outside.pdf")
            try Data("%PDF outside".utf8).write(to: outside)
            try queue.add(data: Data("%PDF inside".utf8), originalFileName: "a.pdf", typeIdentifier: "com.adobe.pdf")
            let item = try #require(queue.scan().items.first)
            let payload = queue.payloadURL(of: item)

            let data = try queue.payload(of: item) {
                try FileManager.default.removeItem(at: payload)
                try FileManager.default.createSymbolicLink(at: payload, withDestinationURL: outside)
            }

            #expect(data == Data("%PDF inside".utf8))
            let swapped = try FileManager.default.attributesOfItem(atPath: payload.path)[.type] as? FileAttributeType
            #expect(swapped == .typeSymbolicLink, "the hook did swap the payload")
        }
    }

    /// K3: a lent file swapped for a link after the writer opened it: the payload is a regular file holding the
    /// lent bytes, never a link and never the link target's bytes.
    @Test func aLentFileSwappedForALinkAfterItWasOpenedIsCopiedNotFollowed() throws {
        try withQueue { queue, container in
            let outside = container.appending(path: "outside.pdf")
            try Data("%PDF outside".utf8).write(to: outside)
            let lent = container.appending(path: "lent.pdf")
            try Data("%PDF lent".utf8).write(to: lent)

            try queue.add(
                copyingFileAt: lent, originalFileName: "lent.pdf", typeIdentifier: "com.adobe.pdf", createdAt: Self.date
            ) {
                try FileManager.default.removeItem(at: lent)
                try FileManager.default.createSymbolicLink(at: lent, withDestinationURL: outside)
            }

            let item = try #require(queue.scan().items.first)
            let type = try FileManager.default.attributesOfItem(atPath: queue.payloadURL(of: item).path)[.type]
            #expect(type as? FileAttributeType == .typeRegular)
            #expect(try queue.payload(of: item) == Data("%PDF lent".utf8))
        }
    }

    /// K4: an item's folder swapped for a link to an outside folder after `scan()`: the reader refuses it and reads
    /// nothing there.
    @Test func anItemFolderSwappedForALinkAfterTheScanIsNotFollowed() throws {
        try withQueue { queue, container in
            let outside = container.appending(path: "outside", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
            try Data("%PDF outside folder".utf8).write(to: outside.appending(path: "payload"))
            let id = try queue.add(
                data: Data("%PDF inside".utf8), originalFileName: "a.pdf", typeIdentifier: "com.adobe.pdf")
            let item = try #require(queue.scan().items.first)
            try swapForALink(queue.itemsFolder.appending(path: id.uuidString), to: outside, keepingIn: container)

            #expect(throws: ShareQueue.NotARegularFile.self) { try queue.payload(of: item) }
        }
    }

    /// K5: a lent FIFO, a lent device (`/dev/null`) and a FIFO as payload are refused. The test holds each FIFO open
    /// itself (read and write, non-blocking), so even an open without `O_NONBLOCK` returns at once and no
    /// regression can hang the run; `theOpenFileIsNonBlocking` pins the flag.
    @Test func aFIFOOrDeviceIsRefusedAndNothingCanHang() throws {
        try withQueue { queue, container in
            let fifo = container.appending(path: "lent-fifo.pdf")
            #expect(mkfifo(fifo.path, 0o600) == 0)
            let heldFIFO = open(fifo.path, O_RDWR | O_NONBLOCK)
            try #require(heldFIFO >= 0)
            defer { close(heldFIFO) }

            for source in [fifo, URL(filePath: "/dev/null")] {
                #expect(throws: ShareQueue.NotARegularFile.self, "\(source.path)") {
                    try queue.add(copyingFileAt: source, originalFileName: "x.pdf", typeIdentifier: "com.adobe.pdf")
                }
            }
            #expect(names(in: queue.incomingFolder).isEmpty && names(in: queue.itemsFolder).isEmpty)

            try queue.add(data: Data("%PDF".utf8), originalFileName: "a.pdf", typeIdentifier: "com.adobe.pdf")
            let item = try #require(queue.scan().items.first)
            let payload = queue.payloadURL(of: item)
            try FileManager.default.removeItem(at: payload)
            #expect(mkfifo(payload.path, 0o600) == 0)
            let heldPayload = open(payload.path, O_RDWR | O_NONBLOCK)
            try #require(heldPayload >= 0)
            defer { close(heldPayload) }

            #expect(throws: ShareQueue.NotARegularFile.self) { try queue.payload(of: item) }
        }
    }

    /// K6: the files the queue opens are non-blocking, so a FIFO cannot hang an open or a read.
    @Test func theOpenFileIsNonBlocking() throws {
        try withQueue { _, container in
            let file = container.appending(path: "f.pdf")
            try Data("%PDF".utf8).write(to: file)
            let folder = try ShareQueue.openFolder(container)
            defer { close(folder) }

            let byPath = try ShareQueue.openRegularFile(file)
            let inFolder = try ShareQueue.openRegularFile(named: "f.pdf", in: folder)

            #expect(fcntl(byPath.fileDescriptor, F_GETFL) & O_NONBLOCK != 0)
            #expect(fcntl(inFolder.fileDescriptor, F_GETFL) & O_NONBLOCK != 0)
        }
    }

    /// K7: a lent file larger than several copy chunks comes through byte for byte (5 MiB and 7 bytes).
    @Test func aLargeLentFileIsCopiedByteForByte() throws {
        try withQueue { queue, container in
            let count = 5 * ShareQueue.copyChunkSize + 7
            // Every byte depends on its offset, so a lost, repeated or shifted chunk shows.
            let bytes = Data((0..<count).map { UInt8(truncatingIfNeeded: $0 ^ ($0 >> 8) ^ ($0 >> 16)) })
            let lent = container.appending(path: "large.pdf")
            try bytes.write(to: lent)

            try queue.add(copyingFileAt: lent, originalFileName: "large.pdf", typeIdentifier: "com.adobe.pdf")

            let item = try #require(queue.scan().items.first)
            let payload = try queue.payload(of: item)
            #expect(payload.count == count)
            #expect(payload == bytes)
        }
    }

    /// K9: an item's folder swapped for a link to an outside folder after `scan()`: counting an attempt writes
    /// nothing there.
    @Test func anAttemptThroughASwappedItemFolderWritesNothingOutside() throws {
        try withQueue { queue, container in
            let outside = container.appending(path: "outside", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
            let outsideJSON = Data(
                #"{"attempts":0,"createdAt":0,"originalFileName":"o.pdf","typeIdentifier":"com.adobe.pdf","version":1}"#
                    .utf8)
            try outsideJSON.write(to: outside.appending(path: "item.json"))
            let id = try queue.add(data: Data("%PDF".utf8), originalFileName: "a.pdf", typeIdentifier: "com.adobe.pdf")
            let item = try #require(queue.scan().items.first)
            try swapForALink(queue.itemsFolder.appending(path: id.uuidString), to: outside, keepingIn: container)

            #expect(throws: ShareQueue.NotARegularFile.self) { try queue.recordAttempt(item) }

            #expect(try Data(contentsOf: outside.appending(path: "item.json")) == outsideJSON)
            #expect(names(in: outside) == ["item.json"], "no temporary file is left outside")
        }
    }

    /// A missing lent file, a missing payload and an item that is gone throw `POSIXError(.ENOENT)`, not
    /// `NotARegularFile`: the share extension (part 2 of #87) tells a refused file from a vanished one by this.
    @Test func aMissingFileOrAGoneItemThrowsENOENT() throws {
        try withQueue { queue, container in
            let missing = container.appending(path: "missing.pdf")
            #expect(
                posixCode {
                    try queue.add(copyingFileAt: missing, originalFileName: "m.pdf", typeIdentifier: "com.adobe.pdf")
                } == .ENOENT)
            #expect(names(in: queue.incomingFolder).isEmpty && names(in: queue.itemsFolder).isEmpty)

            let id = try queue.add(data: Data("%PDF".utf8), originalFileName: "a.pdf", typeIdentifier: "com.adobe.pdf")
            let item = try #require(queue.scan().items.first)
            try FileManager.default.removeItem(at: queue.payloadURL(of: item))
            #expect(posixCode { _ = try queue.payload(of: item) } == .ENOENT, "the payload is missing")

            try queue.remove(id)
            #expect(posixCode { _ = try queue.payload(of: item) } == .ENOENT, "the item is gone")
            #expect(posixCode { _ = try queue.recordAttempt(item) } == .ENOENT, "the item is gone")
        }
    }

    // MARK: Round 2 of #95: bounded memory, the attempt's hooks, descriptors, sockets

    /// How many descriptors this process has open.
    private func openDescriptorCount() -> Int {
        let limit = Int32(clamping: min(Int(getdtablesize()), 1 << 16))
        return (0..<limit).filter { fcntl($0, F_GETFD) != -1 }.count
    }

    /// A Unix domain socket file at `url`. `bind` takes a path of about 100 bytes at most, so the socket is
    /// bound in a short folder of its own (`/tmp` when the temporary folder's path is too long, as in the iOS
    /// simulator) and then moved to `url`.
    private func makeSocket(at url: URL) throws {
        let base =
            FileManager.default.temporaryDirectory.path.utf8.count < 60
            ? FileManager.default.temporaryDirectory.path : "/tmp"
        let folder = URL(filePath: base).appending(
            path: "sq-\(UUID().uuidString.prefix(8))", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appending(path: "s").path
        #if canImport(Glibc)
            let descriptor = socket(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0)
        #else
            let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        #endif
        try #require(descriptor >= 0)
        defer { close(descriptor) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        try #require(bytes.count < MemoryLayout.size(ofValue: address.sun_path))
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: bytes)
            buffer[bytes.count] = 0
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        try #require(bound == 0, "bind: \(errno)")
        try FileManager.default.moveItem(at: URL(filePath: path), to: url)
    }

    #if canImport(Darwin) && !os(macOS)
        /// The process's `phys_footprint` (`task_info`, `TASK_VM_INFO`), in bytes.
        private func physicalFootprint() throws -> Int {
            var info = task_vm_info_data_t()
            var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
            let result = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                    task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
                }
            }
            try #require(result == KERN_SUCCESS)
            return Int(info.phys_footprint)
        }

        /// B1 of the reviews of #95: copying a large lent file keeps memory bounded. 128 MiB are copied; the
        /// footprint right after the copy (before any autorelease pool of the caller drains) may grow by less than
        /// 32 MiB, which leaves room for other tests running at the same time. A copy that kept its chunks grows
        /// by the whole file. The source is sparse (`ftruncate`), so it costs no disk to make.
        /// It reads the footprint after the copy, not its peak during it (#98, point 2), and the shared test
        /// process cannot give a reliable peak. On macOS K11 (`aLargeCopyKeepsPeakMemoryBounded`) replaces it with
        /// the peak in a child process; iOS has no exit tests, so it keeps this weaker check.
        @Test func aLargeCopyKeepsMemoryBounded() throws {
            try withQueue { queue, container in
                let size = 128 * ShareQueue.copyChunkSize
                let lent = container.appending(path: "large-sparse.pdf")
                #expect(FileManager.default.createFile(atPath: lent.path, contents: nil))
                let file = open(lent.path, O_WRONLY)
                try #require(file >= 0)
                #expect(ftruncate(file, off_t(size)) == 0)
                close(file)
                let before = try physicalFootprint()

                try queue.add(copyingFileAt: lent, originalFileName: "large.pdf", typeIdentifier: "com.adobe.pdf")

                let growth = try physicalFootprint() - before
                #expect(growth < 32 * ShareQueue.copyChunkSize, "the footprint grew by \(growth >> 20) MiB")
                let item = try #require(queue.scan().items.first)
                let copied = try FileManager.default.attributesOfItem(atPath: queue.payloadURL(of: item).path)[.size]
                #expect((copied as? NSNumber)?.intValue == size || (copied as? Int) == size)
            }
        }
    #endif

    // MARK: #98, part 1: the payload is mapped, and memory is measured at its peak

    /// A new temporary folder that stands in for the group container, removed after `body`.
    private func withContainer(_ body: (ShareQueue, URL) async throws -> Void) async throws {
        let container = FileManager.default.temporaryDirectory
            .appending(path: "ShareQueueTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: container) }
        try await body(ShareQueue(groupContainer: container), container)
    }

    /// A sparse file of `size` bytes at `url` (`ftruncate`): it costs no disk to make, and reads as zeros.
    private func makeSparseFile(at url: URL, size: Int) throws {
        #expect(FileManager.default.createFile(atPath: url.path, contents: nil))
        let file = open(url.path, O_WRONLY)
        try #require(file >= 0)
        defer { close(file) }
        try #require(ftruncate(file, off_t(size)) == 0)
    }

    #if os(macOS)
        /// K10: a 128 MiB payload is mapped, not copied into memory. The item is written by hand with a sparse
        /// payload, so the test writes no 128 MiB to disk (N5 of the plan review); `readToEnd` still allocates the
        /// whole file on the heap. In a child process (`peakGrowthChild`): `payload(of:)`, then one byte read per
        /// 4 KiB page while the `Data` is held, then the peak may have grown by less than 32 MiB.
        @Test func aLargePayloadIsMappedNotCopied() async throws {
            try await withContainer { queue, _ in
                let folder = queue.itemsFolder.appending(path: UUID().uuidString, directoryHint: .isDirectory)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try makeSparseFile(at: folder.appending(path: "payload"), size: largeSize)
                try Data(
                    #"{"version":1,"originalFileName":"large.pdf","typeIdentifier":"com.adobe.pdf","createdAt":0}"#
                        .utf8
                ).write(to: folder.appending(path: "item.json"))

                await #expect(processExitsWith: .success) {
                    [root = queue.root as URL] in
                    peakGrowthChild {
                        let queue = ShareQueue(root: root)
                        guard let item = queue.scan().items.first else { throw CocoaError(.fileNoSuchFile) }
                        let payload = try queue.payload(of: item)
                        guard payload.count == largeSize else { throw CocoaError(.fileReadCorruptFile) }
                        var sum: UInt8 = 0
                        payload.withUnsafeBytes { bytes in
                            for offset in stride(from: 0, to: bytes.count, by: 4096) { sum &+= bytes[offset] }
                        }
                        guard sum == 0 else { throw CocoaError(.fileReadCorruptFile) }
                    }
                }
            }
        }

        /// K11: copying a 128 MiB lent file keeps the peak bounded, not only the footprint after the copy (#98,
        /// point 2). The lent file is sparse; the copy runs in a child process (`peakGrowthChild`).
        @Test func aLargeCopyKeepsPeakMemoryBounded() async throws {
            try await withContainer { queue, container in
                let lent = container.appending(path: "large-sparse.pdf")
                try makeSparseFile(at: lent, size: largeSize)

                await #expect(processExitsWith: .success) {
                    [root = queue.root as URL, lent = lent as URL] in
                    peakGrowthChild {
                        try ShareQueue(root: root).add(
                            copyingFileAt: lent, originalFileName: "large.pdf", typeIdentifier: "com.adobe.pdf")
                    }
                }
                let item = try #require(queue.scan().items.first)
                let copied = try FileManager.default.attributesOfItem(atPath: queue.payloadURL(of: item).path)[.size]
                #expect((copied as? NSNumber)?.intValue == largeSize || (copied as? Int) == largeSize)
            }
        }
    #endif

    /// K12: a payload larger than several pages comes back byte for byte, also after its item was removed: the
    /// mapping outlives the descriptor and the item (5 MiB and 7 bytes, every byte depending on its offset).
    @Test func aPayloadIsReadByteForByteAndOutlivesItsItem() throws {
        try withQueue { queue, _ in
            let count = 5 * ShareQueue.copyChunkSize + 7
            let bytes = Data((0..<count).map { UInt8(truncatingIfNeeded: $0 ^ ($0 >> 8) ^ ($0 >> 16) ^ 0x5A) })
            let id = try queue.add(data: bytes, originalFileName: "a.pdf", typeIdentifier: "com.adobe.pdf")
            let item = try #require(queue.scan().items.first)

            let payload = try queue.payload(of: item)
            try queue.remove(id)

            #expect(!FileManager.default.fileExists(atPath: queue.payloadURL(of: item).path))
            #expect(payload.count == count)
            #expect(payload == bytes)
            #expect(payload.last == bytes.last)
        }
    }

    /// K13: an empty payload is empty `Data` (`mmap` of length 0 would be `EINVAL`).
    @Test func anEmptyPayloadIsEmptyData() throws {
        try withQueue { queue, _ in
            try queue.add(data: Data(), originalFileName: "empty.pdf", typeIdentifier: "com.adobe.pdf")
            let item = try #require(queue.scan().items.first)

            #expect(try queue.payload(of: item) == Data())
        }
    }

    /// K17 (reviews of #106, A-N1 and B1): a uniquely referenced payload written in place changes the `Data` and
    /// leaves the file as it was. 64 KiB, above `Data`'s inline size, so the write goes into the mapping itself.
    /// With a read-only mapping that write raises `SIGBUS`, so on macOS it runs in a child process and a regression
    /// fails this test instead of ending the suite; elsewhere it runs here (it cannot fault on a writable mapping).
    @Test func aPayloadWrittenInPlaceLeavesTheFileUnchanged() async throws {
        try await withContainer { queue, _ in
            try queue.add(
                data: inPlacePattern(), originalFileName: "a.pdf", typeIdentifier: "com.adobe.pdf")
            #if os(macOS)
                await #expect(processExitsWith: .success) { [root = queue.root as URL] in
                    try writePayloadInPlace(root: root)
                }
            #else
                try writePayloadInPlace(root: queue.root)
            #endif
            let item = try #require(queue.scan().items.first)
            #expect(try Data(contentsOf: queue.payloadURL(of: item)) == inPlacePattern())
        }
    }

    #if os(macOS)
        /// K18 (reviews of #106, A-N2 and B2): releasing the payload's `Data` unmaps it. In a child process, which
        /// runs nothing else, so no other test can map the same addresses in between: the range is mapped while the
        /// `Data` lives (`msync` succeeds) and gone after it was released (`msync` fails with `ENOMEM`).
        @Test func aReleasedPayloadIsUnmapped() async throws {
            try await withContainer { queue, _ in
                try queue.add(
                    data: Data(repeating: 1, count: 1 << 20), originalFileName: "a.pdf", typeIdentifier: "com.adobe.pdf"
                )
                await #expect(processExitsWith: .success) { [root = queue.root as URL] in
                    let queue = ShareQueue(root: root)
                    guard let item = queue.scan().items.first else { throw CocoaError(.fileNoSuchFile) }
                    let range: (base: UnsafeMutableRawPointer, count: Int)? = try {
                        let payload = try queue.payload(of: item)
                        return payload.withUnsafeBytes { bytes in
                            bytes.baseAddress.map { (UnsafeMutableRawPointer(mutating: $0), bytes.count) }
                        }
                    }()
                    guard let range else { throw CocoaError(.fileReadCorruptFile) }
                    // The `Data` is released when the closure above returns.
                    // Still mapped: exit 5, so a leak reads as `.exitCode(5)`, not as a trap.
                    if !(msync(range.base, range.count, MS_ASYNC) == -1 && errno == ENOMEM) { exit(5) }
                }
            }
        }
    #endif

    /// N8: `writeAll` writes everything through short writes and `EINTR`, and throws any other error.
    @Test func writeAllLoopsOverShortWritesAndInterrupts() throws {
        try withQueue { _, container in
            let url = container.appending(path: "written")
            let bytes = Data((0..<1000).map { UInt8(truncatingIfNeeded: $0 &* 7) })
            #expect(FileManager.default.createFile(atPath: url.path, contents: nil))
            let file = open(url.path, O_WRONLY)
            try #require(file >= 0)
            defer { close(file) }
            var calls = 0
            try bytes.withUnsafeBytes { buffer in
                try ShareQueue.writeAll(buffer, to: file) { descriptor, start, count in
                    calls += 1
                    if calls == 2 {
                        errno = EINTR
                        return -1
                    }
                    return write(descriptor, start, min(count, 3))
                }
            }
            #expect(try Data(contentsOf: url) == bytes)
            #expect(calls > 300, "short writes were looped over")

            let failing = posixCode {
                try bytes.withUnsafeBytes { buffer in
                    try ShareQueue.writeAll(buffer, to: file) { _, _, _ in
                        errno = EIO
                        return -1
                    }
                }
            }
            #expect(failing == .EIO)
            #expect(
                posixCode { try bytes.withUnsafeBytes { try ShareQueue.writeAll($0, to: file) { _, _, _ in 0 } } }
                    == .EIO)
        }
    }

    /// A0 of review A: the item's folder swapped for a link during the attempt (after the check, before the write):
    /// the write still goes into the folder that was opened, never into the outside folder.
    @Test func anItemFolderSwappedDuringTheAttemptGetsTheWriteNotTheOutside() throws {
        try withQueue { queue, container in
            let outside = container.appending(path: "outside", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
            let outsideJSON = Data(
                #"{"attempts":0,"createdAt":0,"originalFileName":"o.pdf","typeIdentifier":"com.adobe.pdf","version":1}"#
                    .utf8)
            try outsideJSON.write(to: outside.appending(path: "item.json"))
            let id = try queue.add(data: Data("%PDF".utf8), originalFileName: "a.pdf", typeIdentifier: "com.adobe.pdf")
            let item = try #require(queue.scan().items.first)
            let original = queue.itemsFolder.appending(path: id.uuidString)
            let movedAway = container.appending(path: "moved-away", directoryHint: .isDirectory)

            let counted = try queue.recordAttempt(item) {
                try FileManager.default.moveItem(at: original, to: movedAway)
                try FileManager.default.createSymbolicLink(at: original, withDestinationURL: outside)
            }

            #expect(counted.info.attempts == 1)
            #expect(try Data(contentsOf: outside.appending(path: "item.json")) == outsideJSON)
            #expect(names(in: outside) == ["item.json"])
            let written = try Data(contentsOf: movedAway.appending(path: "item.json"))
            #expect(String(decoding: written, as: UTF8.self).contains(#""attempts":1"#), "written where it was opened")
        }
    }

    /// A1 of review A, R3 of review B: when the new `item.json` cannot be renamed into place (here `item.json` became
    /// a folder after the check), the attempt throws and its temporary file is removed.
    @Test func aFailedAttemptLeavesNoTemporaryFile() throws {
        try withQueue { queue, _ in
            let id = try queue.add(data: Data("%PDF".utf8), originalFileName: "a.pdf", typeIdentifier: "com.adobe.pdf")
            let item = try #require(queue.scan().items.first)
            let folder = queue.itemsFolder.appending(path: id.uuidString)
            let info = folder.appending(path: "item.json")

            #expect(throws: (any Error).self) {
                try queue.recordAttempt(item) {
                    try FileManager.default.removeItem(at: info)
                    try FileManager.default.createDirectory(at: info, withIntermediateDirectories: true)
                    try Data("x".utf8).write(to: info.appending(path: "inside"))
                }
            }

            #expect(names(in: folder) == ["item.json", "payload"], "no .item.json.* is left")
        }
    }

    /// R1 of review B: an `item.json` swapped for a link to outside JSON after `scan()` is not counted (`fstatat`
    /// does not follow it), and neither the link nor its target changes.
    @Test func anItemJSONSwappedForALinkAfterTheScanIsNotCounted() throws {
        try withQueue { queue, container in
            let outside = container.appending(path: "outside.json")
            let outsideJSON = Data(
                #"{"attempts":0,"createdAt":0,"originalFileName":"o.pdf","typeIdentifier":"com.adobe.pdf","version":1}"#
                    .utf8)
            try outsideJSON.write(to: outside)
            let id = try queue.add(data: Data("%PDF".utf8), originalFileName: "a.pdf", typeIdentifier: "com.adobe.pdf")
            let item = try #require(queue.scan().items.first)
            let info = queue.itemsFolder.appending(path: id.uuidString).appending(path: "item.json")
            try swapForALink(info, to: outside, keepingIn: container)

            var code: CocoaError.Code?
            do {
                _ = try queue.recordAttempt(item)
            } catch let error as CocoaError {
                code = error.code
            }

            #expect(code == .fileNoSuchFile)
            #expect(try Data(contentsOf: outside) == outsideJSON)
            let type = try FileManager.default.attributesOfItem(atPath: info.path)[.type] as? FileAttributeType
            #expect(type == .typeSymbolicLink, "the link itself stays")
        }
    }

    /// A2 of review A: a refused file's descriptor is closed. 50 rounds of a lent folder, a lent device and a folder
    /// as payload leave the number of open descriptors where it was (a little room for other tests running at the
    /// same time; a leak adds 150).
    @Test func refusedFilesLeaveNoOpenDescriptor() throws {
        try withQueue { queue, container in
            let folder = container.appending(path: "folder.pdf", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try queue.add(data: Data("%PDF".utf8), originalFileName: "a.pdf", typeIdentifier: "com.adobe.pdf")
            let item = try #require(queue.scan().items.first)
            try FileManager.default.removeItem(at: queue.payloadURL(of: item))
            try FileManager.default.createDirectory(at: queue.payloadURL(of: item), withIntermediateDirectories: true)
            let before = openDescriptorCount()

            for _ in 0..<50 {
                for source in [folder, URL(filePath: "/dev/null")] {
                    #expect(throws: ShareQueue.NotARegularFile.self) {
                        try queue.add(copyingFileAt: source, originalFileName: "x.pdf", typeIdentifier: "com.adobe.pdf")
                    }
                }
                #expect(throws: ShareQueue.NotARegularFile.self) { try queue.payload(of: item) }
            }

            let after = openDescriptorCount()
            #expect(after - before < 25, "\(before) open descriptors before, \(after) after")
        }
    }

    /// N2 of review A: a socket, lent or as payload, is `NotARegularFile` (`open` gives `EOPNOTSUPP` on Apple
    /// platforms and `ENXIO` on Linux), and nothing is written.
    @Test func aSocketLentOrAsPayloadIsRefused() throws {
        try withQueue { queue, container in
            let lent = container.appending(path: "lent-socket.pdf")
            try makeSocket(at: lent)

            #expect(throws: ShareQueue.NotARegularFile.self) {
                try queue.add(copyingFileAt: lent, originalFileName: "s.pdf", typeIdentifier: "com.adobe.pdf")
            }
            #expect(names(in: queue.incomingFolder).isEmpty && names(in: queue.itemsFolder).isEmpty)

            try queue.add(data: Data("%PDF".utf8), originalFileName: "a.pdf", typeIdentifier: "com.adobe.pdf")
            let item = try #require(queue.scan().items.first)
            try FileManager.default.removeItem(at: queue.payloadURL(of: item))
            try makeSocket(at: queue.payloadURL(of: item))

            #expect(throws: ShareQueue.NotARegularFile.self) { try queue.payload(of: item) }
        }
    }

    // MARK: #87, part 2: the extension's data fallback (option B)

    /// What `add(copyingFileAt:…)` threw for `source`; `nil` when it copied.
    private func addError(copying source: URL, to queue: ShareQueue) -> (any Error)? {
        do {
            try queue.add(copyingFileAt: source, originalFileName: "lent.pdf", typeIdentifier: "com.adobe.pdf")
            return nil
        } catch {
            return error
        }
    }

    /// K8: the extension falls back to the data only when the lent file was not refused. A lent link (absolute or
    /// relative), folder or device is `NotARegularFile`: no fallback, so the link's target is never read. A file
    /// that is gone (`ENOENT`), any other error of the open and no lent file at all (`nil`) fall back; a failure
    /// after the open is `CopyFailed` and does not (#104, P1 = A: K14 to K16).
    @Test func fallsBackToDataOnlyForFilesThatAreNotRefused() throws {
        try withQueue { queue, container in
            let (_, absoluteLink) = try outsideFileAndLink(in: container)
            let relativeLink = container.appending(path: "relative-link.pdf")
            try FileManager.default.createSymbolicLink(
                atPath: relativeLink.path, withDestinationPath: "outside-secret.pdf")
            let folder = container.appending(path: "folder.pdf", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

            for refused in [absoluteLink, relativeLink, folder, URL(filePath: "/dev/null")] {
                let error = addError(copying: refused, to: queue)
                #expect(
                    error is ShareQueue.NotARegularFile, "\(refused.lastPathComponent): \(String(describing: error))")
                #expect(!ShareQueue.fallsBackToData(afterFileError: error), "\(refused.lastPathComponent)")
            }

            let gone = addError(copying: container.appending(path: "gone.pdf"), to: queue)
            #expect((gone as? POSIXError)?.code == .ENOENT)
            #expect(ShareQueue.fallsBackToData(afterFileError: gone), "a lent file that is gone")
            #expect(names(in: queue.incomingFolder).isEmpty && names(in: queue.itemsFolder).isEmpty)
        }
        #expect(!ShareQueue.fallsBackToData(afterFileError: ShareQueue.NotARegularFile()))
        #expect(ShareQueue.fallsBackToData(afterFileError: POSIXError(.ENOENT)))
        #expect(ShareQueue.fallsBackToData(afterFileError: CocoaError(.fileReadNoSuchFile)))
        #expect(ShareQueue.fallsBackToData(afterFileError: POSIXError(.EACCES)))
        #expect(ShareQueue.fallsBackToData(afterFileError: nil), "no file lent")
    }

    // MARK: #104: the share order in Kit; no data fallback once the lent file was opened (P1 = A)

    /// What the extension's file step reports in K14.
    enum FileOutcome: String, CaseIterable, Sendable {
        case saved, notARegularFile, gone, notPermitted, cocoaNoSuchFile, noFileLent, copyFailed

        var step: ShareQueue.FileStep {
            switch self {
            case .saved: .saved
            case .notARegularFile: .notSaved(ShareQueue.NotARegularFile())
            case .gone: .notSaved(POSIXError(.ENOENT))
            case .notPermitted: .notSaved(POSIXError(.EACCES))
            case .cocoaNoSuchFile: .notSaved(CocoaError(.fileReadNoSuchFile))
            case .noFileLent: .notSaved(nil)
            case .copyFailed: .notSaved(ShareQueue.CopyFailed(underlying: POSIXError(.ENOSPC)))
            }
        }

        /// Whether `saveAttachment` may load the data after this outcome.
        var fallsBack: Bool {
            switch self {
            case .saved, .notARegularFile, .copyFailed: false
            case .gone, .notPermitted, .cocoaNoSuchFile, .noFileLent: true
            }
        }
    }

    /// K14: `saveAttachment` holds the extension's order. The file step runs once; a saved file is `true` without the
    /// data; `NotARegularFile` and `CopyFailed` are `false` without the data; no file lent and a lent file that could
    /// not be opened load the data once, and its result is the attachment's.
    @Test(arguments: FileOutcome.allCases, [true, false])
    func theShareOrderFallsBackOnlyWhenAllowed(_ outcome: FileOutcome, dataSaves: Bool) async {
        var fileCalls = 0
        var dataCalls = 0
        let saved = await ShareQueue.saveAttachment(
            savingFile: {
                fileCalls += 1
                return outcome.step
            },
            savingData: {
                dataCalls += 1
                return dataSaves
            })
        #expect(fileCalls == 1)
        #expect(dataCalls == (outcome.fallsBack ? 1 : 0))
        #expect(saved == (outcome == .saved || (outcome.fallsBack && dataSaves)))
    }

    /// K15: a copy that runs out of space after the lent file was opened (`write(2)` fails with `ENOSPC` on the
    /// second of three 1 MiB chunks) throws `CopyFailed` with `ENOSPC`, leaves nothing in `Incoming/` or `Items/`,
    /// and does not fall back to the data: `saveAttachment` never calls it.
    @Test func aCopyThatRunsOutOfSpaceIsNotSavedAndDoesNotFallBack() async throws {
        try await withContainer { queue, container in
            let lent = container.appending(path: "lent.pdf")
            try Data(repeating: 0x25, count: 3 * ShareQueue.copyChunkSize).write(to: lent)
            var writes = 0
            var thrown: (any Error)?
            do {
                try queue.add(
                    copyingFileAt: lent, originalFileName: "lent.pdf", typeIdentifier: "com.adobe.pdf",
                    createdAt: Self.date, afterOpen: nil
                ) { descriptor, bytes, count in
                    writes += 1
                    guard writes < 2 else {
                        errno = ENOSPC
                        return -1
                    }
                    return write(descriptor, bytes, count)
                }
            } catch {
                thrown = error
            }

            let copyFailed = try #require(thrown as? ShareQueue.CopyFailed, "\(String(describing: thrown))")
            #expect((copyFailed.underlying as? POSIXError)?.code == .ENOSPC)
            #expect(writes == 2, "the copy stopped at the failing chunk")
            #expect(names(in: queue.incomingFolder).isEmpty)
            #expect(names(in: queue.itemsFolder).isEmpty)
            #expect(!ShareQueue.fallsBackToData(afterFileError: thrown))

            var dataCalls = 0
            let saved = await ShareQueue.saveAttachment(
                savingFile: { .notSaved(thrown) },
                savingData: {
                    dataCalls += 1
                    return true
                })
            #expect(!saved)
            #expect(dataCalls == 0, "no data fallback after a failed copy")
        }
    }

    /// K16: a queue that cannot be written (`Incoming` is a regular file, so the item's folder cannot be made) throws
    /// `CopyFailed` for a lent file that was opened, writes nothing and does not fall back.
    @Test func aQueueThatCannotBeWrittenDoesNotFallBack() throws {
        try withQueue { queue, container in
            try FileManager.default.createDirectory(at: queue.root, withIntermediateDirectories: true)
            try Data("not a folder".utf8).write(to: queue.incomingFolder)
            let lent = container.appending(path: "lent.pdf")
            try Data("%PDF lent".utf8).write(to: lent)

            let error = addError(copying: lent, to: queue)

            #expect(error is ShareQueue.CopyFailed, "\(String(describing: error))")
            #expect(!ShareQueue.fallsBackToData(afterFileError: error))
            #expect(try Data(contentsOf: queue.incomingFolder) == Data("not a folder".utf8))
            #expect(names(in: queue.itemsFolder).isEmpty)
        }
    }
}

/// The size of the large files of K10 and K11: 128 MiB.
private let largeSize = 128 << 20

#if os(macOS)
    /// The process's `phys_footprint` and its peak, `ledger_phys_footprint_peak` (`task_info`, `TASK_VM_INFO`), in
    /// bytes; `nil` when `task_info` fails.
    private func footprintAndPeak() -> (now: Int, peak: Int)? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return (Int(info.phys_footprint), Int(info.ledger_phys_footprint_peak))
    }

    /// The body of an exit test (#98, point 2): runs `step` in this fresh child process and exits with how far the
    /// footprint's peak rose above the footprint before it. The peak only ever rises over a process's lifetime and
    /// tests run in parallel, so only a fresh process gives the step's own peak. Exits 0 when it rose by less than
    /// 32 MiB, 3 when not, 2 when the measurement cannot be trusted (no reading, or a peak already 8 MiB or more
    /// above the footprint before the step), 4 when `step` threw. Writes the numbers to standard error (an exit test
    /// shows them with `observing: [\.standardErrorContent]` when it expects the exit code it got).
    private func peakGrowthChild(_ step: () throws -> Void) -> Never {
        func report(_ text: String, exitCode: Int32) -> Never {
            FileHandle.standardError.write(Data("\(text)\n".utf8))
            exit(exitCode)
        }
        let mebibyte = 1 << 20
        guard let before = footprintAndPeak() else { report("no task_info", exitCode: 2) }
        guard before.peak - before.now < 8 * mebibyte else {
            report("peak \(before.peak / mebibyte) MiB before the step, now \(before.now / mebibyte)", exitCode: 2)
        }
        do {
            try step()
        } catch {
            report("the step threw \(error)", exitCode: 4)
        }
        guard let after = footprintAndPeak() else { report("no task_info", exitCode: 2) }
        let growth = after.peak - before.now
        let numbers =
            "before \(before.now / mebibyte)/\(before.peak / mebibyte) MiB, after \(after.now / mebibyte)/"
            + "\(after.peak / mebibyte) MiB (now/peak), peak growth \(growth / mebibyte) MiB"
        report(numbers, exitCode: growth < 32 * mebibyte ? 0 : 3)
    }
#endif

/// K17's payload: 64 KiB, every byte depending on its offset.
private func inPlacePattern() -> Data {
    Data((0..<(64 << 10)).map { UInt8(truncatingIfNeeded: $0 ^ ($0 >> 8) ^ 0x33) })
}

/// K17's step: maps the queue's only item, writes into the uniquely referenced `Data` at its first, middle and last
/// byte, and checks that the `Data` changed. Throws when it did not.
private func writePayloadInPlace(root: URL) throws {
    let queue = ShareQueue(root: root)
    guard let item = queue.scan().items.first else { throw CocoaError(.fileNoSuchFile) }
    var payload = try queue.payload(of: item)
    let original = inPlacePattern()
    for offset in [0, payload.count / 2, payload.count - 1] {
        payload[offset] = ~original[offset]
    }
    for offset in [0, payload.count / 2, payload.count - 1] where payload[offset] != ~original[offset] {
        throw CocoaError(.fileWriteUnknown)
    }
}
