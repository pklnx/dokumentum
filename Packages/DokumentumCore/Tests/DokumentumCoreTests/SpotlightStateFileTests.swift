import DokumentumCore
import DokumentumCoreTestSupport
import DokumentumKit
import DokumentumTestSupport
import Foundation
import Testing

/// The Spotlight state on disk (#13, part 1; plan §3): a round trip, excluded from backup (the file and its folder), a
/// missing file is no state, a file that does not decode is no state, one that cannot be read throws, and a removal.
struct SpotlightStateFileTests {
    static let state = SpotlightState(
        storeIdentity: "CloudKit|/Library/Application Support/Dokumentum/Dokumentum.store", formatVersion: 1,
        localeIdentifier: "de_DE", clientState: Data("generation/3".utf8), batchCount: 3,
        history: .token(Data("{\"t\":1}".utf8)), pendingFullPass: nil,
        fingerprints: ["00000000-0000-4000-8000-00000000000A": "ab", "00000000-0000-4000-8000-00000000000B": "cd"])

    @Test func aRoundTripExcludedFromBackup() throws {
        let folder = try TestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = SpotlightStateFile(url: folder.appending(path: "Spotlight/State.json"))
        #expect(try file.load() == nil, "a missing file is no state")
        try file.save(Self.state)
        #expect(try file.load() == Self.state)
        // A new value for the same file: the flag survives the atomic replacement.
        var pending = Self.state
        pending.pendingFullPass = .start
        pending.history = nil
        try file.save(pending)
        #expect(try file.load() == pending)
        let values = try file.url.resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(values.isExcludedFromBackup == true)
        let folderValues = try file.url.deletingLastPathComponent().resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(folderValues.isExcludedFromBackup == true)

        try file.remove()
        #expect(try file.load() == nil)
        try file.remove()
    }

    @Test func aFileThatDoesNotDecodeIsNoState() throws {
        let folder = try TestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appending(path: "State.json")
        try Data("[\"not\", \"a state\"]".utf8).write(to: url)
        #expect(try SpotlightStateFile(url: url).load() == nil)
    }

    /// A folder where the file should be cannot be read: the load throws, so the pass changes nothing.
    @Test func aFileThatCannotBeReadThrows() throws {
        let folder = try TestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appending(path: "State.json")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        #expect(throws: (any Error).self) { try SpotlightStateFile(url: url).load() }
    }

    @Test func theAppsFileIsInApplicationSupportNotTheAppGroup() {
        #expect(
            SpotlightStateFile.defaultURL.path(percentEncoded: false).hasSuffix(
                "/Application Support/Dokumentum/Spotlight/State.json"))
    }

    /// The setting: on by default (Q2), stored per suite, and back to the default after `reset()`.
    @Test func theSettingIsOnByDefaultAndStoredInItsSuite() throws {
        let suite = "DokumentumTests.Spotlight.\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let settings = SpotlightSettings(suiteName: suite)
        #expect(settings.isEnabled)
        settings.setEnabled(false)
        #expect(!settings.isEnabled)
        #expect(UserDefaults(suiteName: suite)?.object(forKey: SpotlightSettings.key) as? Bool == false)
        #expect(SpotlightSettings(suiteName: "DokumentumTests.Spotlight.other.\(UUID().uuidString)").isEnabled)
        settings.reset()
        #expect(settings.isEnabled)
    }

    @Test func theStoreIdentityNamesTheStoreAndItsFile() {
        let archive = SpotlightIndexer.Configuration.storeIdentity(
            opened: .cloudKit, url: URL(filePath: "/tmp/Dokumentum/Dokumentum.store"))
        let fallback = SpotlightIndexer.Configuration.storeIdentity(
            opened: .localFallback, url: URL(filePath: "/tmp/Dokumentum/Dokumentum-local.store"))
        #expect(archive != fallback)
        #expect(archive == "CloudKit|/tmp/Dokumentum/Dokumentum.store")
        #expect(
            SpotlightIndexer.Configuration.storeIdentity(
                opened: .local, url: URL(filePath: "/tmp/Dokumentum/Dokumentum.store"))
                != archive)
    }
}
