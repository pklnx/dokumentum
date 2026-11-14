import DokumentumKit
import Foundation

/// This device's Spotlight state on disk (#13, plan §3): JSON in Application Support, **excluded from backup**, the file
/// and its folder (as `ScheduledSetFile` of #12, part 3). A backup or a new device therefore brings no state: the index
/// is per device, and a missing state is a full pass.
///
/// - A missing file is no state.
/// - A file that reads but does not decode is no state, logged; the full pass writes it again.
/// - A file that cannot be read throws, so the pass changes nothing.
public struct SpotlightStateFile: SpotlightStateStoring {
    public let url: URL

    /// `<Application Support>/Dokumentum/Spotlight/State.json`, next to the store, never in the app group.
    public static var defaultURL: URL {
        URL.applicationSupportDirectory.appending(path: "Dokumentum/Spotlight/State.json")
    }

    public init(url: URL = SpotlightStateFile.defaultURL) {
        self.url = url
    }

    public func load() throws -> SpotlightState? {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return nil
        }
        guard let state = try? JSONDecoder().decode(SpotlightState.self, from: data) else {
            Log.spotlight.error("The Spotlight state file does not decode; a full pass writes it again")
            return nil
        }
        return state
    }

    public func save(_ state: SpotlightState) throws {
        var folder = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(state).write(to: url, options: .atomic)
        // An atomic write replaces the file, and with it the flag: set it again after every write.
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var file = url
        try file.setResourceValues(values)
        try folder.setResourceValues(values)
    }

    public func remove() throws {
        do {
            try FileManager.default.removeItem(at: url)
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
            return
        }
    }
}
