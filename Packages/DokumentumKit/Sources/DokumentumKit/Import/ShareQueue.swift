import Foundation

/// The hand-over from the share extension to the app (plan of #4, part 4): a folder in the app group,
/// `ShareQueue/`, that the extension writes and the app reads. The extension never opens the archive; it
/// links this package only.
///
/// ```
/// ShareQueue/
///   Incoming/<UUID>/   an item being written (the extension)
///   Items/<UUID>/      finished items, the only folder the app reads
///     payload          the shared bytes, always under this name
///     item.json        `ShareQueueItem.Info`
///   Failed/<UUID>/     items the app gave up on; never emptied automatically (PQ6)
/// ```
///
/// - **Atomic hand-over.** The writer builds an item in `Incoming/` and renames its folder into `Items/` as the
///   last step (one rename on one volume). The reader lists `Items/` only, so it never sees a half-written item.
///   Leftovers in `Incoming/` (the extension ended before the rename) are removed after a day.
/// - **A file name is data, never a path.** The payload is always `payload`. `originalFileName` is used for the
///   title only, and only through `fileName(fromShared:)`: `../../x.pdf` gives `x.pdf`.
/// - **Versions.** An `item.json` with a newer `version` (a newer extension than app) is left alone; one that
///   cannot be read moves to `Failed/`.
/// - **Attempts.** The reader counts an attempt in `item.json` (written `.atomic`) before it imports an item;
///   at `maxAttempts` the item moves to `Failed/`.
///
/// Foundation only, so it is tested on Linux. Every method works on the file system directly and is safe to
/// call from any thread; two processes may use one queue at the same time.
public struct ShareQueue: Sendable {
    /// The app group of the iOS app and its share extension (plan.md, section 2).
    public static let appGroupIdentifier = "group.space.pklnx.dokumentum"
    /// The queue's folder in the group container.
    public static let folderName = "ShareQueue"
    /// The `item.json` version this build writes and reads.
    public static let currentVersion = 1
    /// Attempts after which an item moves to `Failed/`.
    public static let maxAttempts = 3
    /// How old an `Incoming/` leftover must be before the app removes it.
    public static let incomingMaxAge: TimeInterval = 24 * 60 * 60

    static let payloadName = "payload"
    static let infoName = "item.json"

    /// `ShareQueue/` itself.
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    /// The queue in an app group container (`containerURL(forSecurityApplicationGroupIdentifier:)`).
    public init(groupContainer: URL) {
        self.init(root: groupContainer.appending(path: Self.folderName, directoryHint: .isDirectory))
    }

    public var itemsFolder: URL { root.appending(path: "Items", directoryHint: .isDirectory) }
    public var incomingFolder: URL { root.appending(path: "Incoming", directoryHint: .isDirectory) }
    public var failedFolder: URL { root.appending(path: "Failed", directoryHint: .isDirectory) }

    // MARK: Writing (the share extension)

    /// Adds a copy of the file at `source` (a file the system lends for the duration of a call) and returns
    /// the item's identifier. The item appears in `Items/` complete or not at all.
    @discardableResult
    public func add(
        copyingFileAt source: URL, originalFileName: String, typeIdentifier: String, createdAt: Date = Date()
    ) throws -> UUID {
        try add(originalFileName: originalFileName, typeIdentifier: typeIdentifier, createdAt: createdAt) {
            try FileManager.default.copyItem(at: source, to: $0)
        }
    }

    /// Adds `data` as an item; see `add(copyingFileAt:…)`.
    @discardableResult
    public func add(data: Data, originalFileName: String, typeIdentifier: String, createdAt: Date = Date()) throws
        -> UUID
    {
        try add(originalFileName: originalFileName, typeIdentifier: typeIdentifier, createdAt: createdAt) {
            try data.write(to: $0)
        }
    }

    private func add(
        originalFileName: String, typeIdentifier: String, createdAt: Date, writePayload: (URL) throws -> Void
    ) throws -> UUID {
        let id = UUID()
        let fileManager = FileManager.default
        let building = incomingFolder.appending(path: id.uuidString, directoryHint: .isDirectory)
        do {
            try fileManager.createDirectory(at: building, withIntermediateDirectories: true)
            try writePayload(building.appending(path: Self.payloadName))
            let info = ShareQueueItem.Info(
                version: Self.currentVersion, originalFileName: originalFileName, typeIdentifier: typeIdentifier,
                createdAt: createdAt, attempts: 0)
            try Self.write(info, to: building)
            try fileManager.createDirectory(at: itemsFolder, withIntermediateDirectories: true)
            // The last step: from here on the reader sees the item, complete.
            try fileManager.moveItem(at: building, to: itemFolder(id))
        } catch {
            try? fileManager.removeItem(at: building)
            throw error
        }
        return id
    }

    // MARK: Reading (the app)

    /// What `scan()` found.
    public struct Scan: Sendable {
        /// The readable items of this version, oldest first (`createdAt`, then the identifier).
        public var items: [ShareQueueItem] = []
        /// Folder names in `Items/` that could not be read and were moved to `Failed/`.
        public var movedToFailed: [String] = []
        /// Items of a newer version, left where they are.
        public var newerVersion: [UUID] = []
    }

    /// Lists `Items/`, oldest first. An entry that cannot be read (no or broken `item.json`, a name that is not
    /// an identifier) moves to `Failed/`; one of a newer version stays. A missing queue is an empty one.
    public func scan() -> Scan {
        var scan = Scan()
        let fileManager = FileManager.default
        guard let names = try? fileManager.contentsOfDirectory(atPath: itemsFolder.path) else { return scan }
        for name in names.sorted() {
            guard let id = UUID(uuidString: name) else {
                if (try? moveToFailed(named: name)) != nil { scan.movedToFailed.append(name) }
                continue
            }
            switch Self.readInfo(in: itemFolder(id)) {
            case .info(let info):
                scan.items.append(ShareQueueItem(id: id, info: info))
            case .newerVersion:
                scan.newerVersion.append(id)
            case .unreadable:
                if (try? moveToFailed(named: name)) != nil { scan.movedToFailed.append(name) }
            }
        }
        scan.items.sort { ($0.info.createdAt, $0.id.uuidString) < ($1.info.createdAt, $1.id.uuidString) }
        return scan
    }

    /// Counts one attempt in the item's `item.json` (atomically) and returns the item as written. Throws when the
    /// item is gone or cannot be written; the caller then leaves it for the next run.
    public func recordAttempt(_ item: ShareQueueItem) throws -> ShareQueueItem {
        var info = item.info
        info.attempts += 1
        let folder = itemFolder(item.id)
        guard FileManager.default.fileExists(atPath: folder.appending(path: Self.infoName).path) else {
            throw CocoaError(.fileNoSuchFile)
        }
        try Self.write(info, to: folder)
        return ShareQueueItem(id: item.id, info: info)
    }

    /// Where the item's bytes are.
    public func payloadURL(of item: ShareQueueItem) -> URL {
        itemFolder(item.id).appending(path: Self.payloadName)
    }

    /// Removes the item. An item that is gone already is no error.
    /// - Returns: whether this call removed it.
    @discardableResult
    public func remove(_ id: UUID) throws -> Bool {
        let folder = itemFolder(id)
        do {
            try FileManager.default.removeItem(at: folder)
            return true
        } catch {
            // Gone already, by another call: not an error.
            if !FileManager.default.fileExists(atPath: folder.path) { return false }
            throw error
        }
    }

    /// Moves the item to `Failed/`, where nothing removes it.
    public func moveToFailed(_ id: UUID) throws {
        try moveToFailed(named: id.uuidString)
    }

    /// Removes the folders in `Incoming/` last changed more than `incomingMaxAge` before `now`: items the
    /// extension never finished. Returns how many it removed.
    @discardableResult
    public func removeStaleIncoming(now: Date = Date()) -> Int {
        let fileManager = FileManager.default
        guard let names = try? fileManager.contentsOfDirectory(atPath: incomingFolder.path) else { return 0 }
        var removed = 0
        for name in names {
            let url = incomingFolder.appending(path: name)
            guard let changed = try? fileManager.attributesOfItem(atPath: url.path)[.modificationDate] as? Date,
                now.timeIntervalSince(changed) > Self.incomingMaxAge
            else { continue }
            if (try? fileManager.removeItem(at: url)) != nil { removed += 1 }
        }
        return removed
    }

    // MARK: Names

    /// The file name a shared name stands for, as data: its last path component (after `/` or `\`), without
    /// control characters and the whitespace around it. `../../x.pdf` gives `x.pdf`; the importer makes the
    /// title `x` from it.
    public static func fileName(fromShared name: String) -> String {
        let last = name.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? ""
        let scalars = last.unicodeScalars.filter { $0.properties.generalCategory != .control }
        return String(scalars).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Private

    private func itemFolder(_ id: UUID) -> URL {
        itemsFolder.appending(path: id.uuidString, directoryHint: .isDirectory)
    }

    private func moveToFailed(named name: String) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: failedFolder, withIntermediateDirectories: true)
        var target = failedFolder.appending(path: name, directoryHint: .isDirectory)
        if fileManager.fileExists(atPath: target.path) {
            // Never over an earlier failed item.
            target = failedFolder.appending(path: "\(name)-\(UUID().uuidString)", directoryHint: .isDirectory)
        }
        try fileManager.moveItem(at: itemsFolder.appending(path: name), to: target)
    }

    private enum ReadInfo {
        case info(ShareQueueItem.Info)
        case newerVersion
        case unreadable
    }

    private static func readInfo(in folder: URL) -> ReadInfo {
        guard let data = try? Data(contentsOf: folder.appending(path: infoName)) else { return .unreadable }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        guard let version = try? decoder.decode(VersionOnly.self, from: data).version, version >= 1 else {
            return .unreadable
        }
        if version > currentVersion { return .newerVersion }
        guard let info = try? decoder.decode(ShareQueueItem.Info.self, from: data) else { return .unreadable }
        return .info(info)
    }

    private struct VersionOnly: Decodable {
        var version: Int
    }

    private static func write(_ info: ShareQueueItem.Info, to folder: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        // Atomic: the reader rewrites it to count attempts, and a crash must not leave half a file.
        try encoder.encode(info).write(to: folder.appending(path: infoName), options: .atomic)
    }
}

/// One finished item in `Items/`.
public struct ShareQueueItem: Hashable, Sendable {
    /// `item.json`.
    public struct Info: Codable, Hashable, Sendable {
        public var version: Int
        /// The name the sharing app gave; data only (`ShareQueue.fileName(fromShared:)`).
        public var originalFileName: String
        /// The type the payload was loaded as, such as `com.adobe.pdf` or `public.jpeg`.
        public var typeIdentifier: String
        public var createdAt: Date
        /// Attempts the app counted before importing; missing in a new item.
        public var attempts: Int

        public init(version: Int, originalFileName: String, typeIdentifier: String, createdAt: Date, attempts: Int) {
            self.version = version
            self.originalFileName = originalFileName
            self.typeIdentifier = typeIdentifier
            self.createdAt = createdAt
            self.attempts = attempts
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            version = try container.decode(Int.self, forKey: .version)
            originalFileName = try container.decode(String.self, forKey: .originalFileName)
            typeIdentifier = try container.decode(String.self, forKey: .typeIdentifier)
            createdAt = try container.decode(Date.self, forKey: .createdAt)
            attempts = try container.decodeIfPresent(Int.self, forKey: .attempts) ?? 0
        }
    }

    public let id: UUID
    public let info: Info

    public init(id: UUID, info: Info) {
        self.id = id
        self.info = info
    }

    /// The file name the importer gets: the shared name as data (`ShareQueue.fileName(fromShared:)`).
    public var fileName: String { ShareQueue.fileName(fromShared: info.originalFileName) }

    /// Whether the item has had all its attempts (`ShareQueue.maxAttempts`) and belongs in `Failed/`.
    public var hasNoAttemptsLeft: Bool { info.attempts >= ShareQueue.maxAttempts }
}
