import DokumentumCore
import DokumentumCoreTestSupport
import DokumentumKit
import DokumentumTestSupport
import Foundation
import Testing

/// `S` on disk (#12, part 3; plan §7, re-review N2): a round trip, excluded from backup (the file and its folder), a
/// missing file is empty, a file that is no list starts empty, and one that cannot be read throws.
struct ScheduledSetFileTests {
    private static let identifiers: Set<String> = [
        "deadline.00000000-0000-4000-8000-00000000000A.2026-11-27",
        "deadline.00000000-0000-4000-8000-00000000000B.2026-12-04",
    ]

    @Test func aRoundTripExcludedFromBackup() throws {
        let folder = try TestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = ScheduledSetFile(url: folder.appending(path: "Reminders/Scheduled.json"))
        #expect(try file.load().isEmpty, "a missing file is an empty set")
        try file.save(Self.identifiers)
        #expect(try file.load() == Self.identifiers)
        // A new value for the same file: the flag survives the atomic replacement.
        try file.save([])
        try file.save(Self.identifiers)
        #expect(try file.load() == Self.identifiers)
        let values = try file.url.resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(values.isExcludedFromBackup == true)
        let folderValues = try file.url.deletingLastPathComponent().resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(folderValues.isExcludedFromBackup == true)
    }

    @Test func aFileThatIsNoListStartsEmpty() throws {
        let folder = try TestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appending(path: "Scheduled.json")
        try Data("{\"not\": \"a list\"}".utf8).write(to: url)
        #expect(try ScheduledSetFile(url: url).load().isEmpty)
    }

    /// A folder where the file should be cannot be read: the load throws, so the reconcile changes nothing.
    @Test func aFileThatCannotBeReadThrows() throws {
        let folder = try TestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appending(path: "Scheduled.json")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        #expect(throws: (any Error).self) { try ScheduledSetFile(url: url).load() }
    }

    @Test func theAppsFileIsInApplicationSupportNotTheAppGroup() {
        #expect(
            ScheduledSetFile.defaultURL.path(percentEncoded: false).hasSuffix(
                "/Application Support/Dokumentum/Reminders/Scheduled.json"))
    }
}
