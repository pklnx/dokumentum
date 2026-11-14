import DokumentumKit
import Foundation

/// This device's scheduled set `S` on disk (#12, part 3; plan §7, re-review N2): a JSON list of identifiers in
/// Application Support, **excluded from backup**, the file and its folder. A backup or a new device therefore brings
/// no stale `S`: a new device is a new device, and reminds once by its own settings.
///
/// - A missing file is an empty set (the first launch).
/// - A file that cannot be read throws, so the reconcile changes nothing (as a failed deadline read).
/// - A file that reads but is not a list of strings is an empty set, logged, and is written again by the reconcile.
public struct ScheduledSetFile: ScheduledSetStoring {
    public let url: URL

    /// `<Application Support>/Dokumentum/Reminders/Scheduled.json`, next to the store, never in the app group.
    public static var defaultURL: URL {
        URL.applicationSupportDirectory.appending(path: "Dokumentum/Reminders/Scheduled.json")
    }

    public init(url: URL = ScheduledSetFile.defaultURL) {
        self.url = url
    }

    public func load() throws -> Set<String> {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return []
        }
        guard let identifiers = try? JSONDecoder().decode([String].self, from: data) else {
            Log.reminders.error("The scheduled reminders file is not a list; it starts again empty")
            return []
        }
        return Set(identifiers)
    }

    public func save(_ scheduled: Set<String>) throws {
        var folder = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try JSONEncoder().encode(scheduled.sorted()).write(to: url, options: .atomic)
        // An atomic write replaces the file, and with it the flag: set it again after every write.
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var file = url
        try file.setResourceValues(values)
        try folder.setResourceValues(values)
    }
}
