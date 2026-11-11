import Foundation

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#elseif canImport(Musl)
    import Musl
#endif

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
/// - **Regular files only, opened once, no symbolic link from the item's folder down** (reviews of #85, #87).
///   Every file is opened once (`O_NOFOLLOW`, `O_NONBLOCK`) and checked on the open descriptor (`fstat`): a
///   symbolic link, a folder, a FIFO, a socket or a device is refused as `NotARegularFile`, and a link swapped in
///   after the open is never followed. The writer copies from that descriptor through one `copyChunkSize` buffer,
///   so a file is never held in memory; the reader maps the payload from it (below). Inside an item, `payload` and
///   `item.json` are opened, and `item.json` is rewritten, only through the descriptor of the item's folder, itself
///   opened without following a link (`O_DIRECTORY`, `O_NOFOLLOW`): an item folder swapped for a link is refused, and
///   nothing is read or written through it. A linked `item.json` makes the item unreadable (`Failed/`), and an entry of
///   `Items/` is read only when it is a real folder. A missing file is `POSIXError(.ENOENT)`.
///   What this does not cover, by design: a symbolic link at `ShareQueue/` or `Items/` is followed (both are
///   reached by path; our own code creates them, and swapping them needs the same group access), so is one among
///   the folders above a lent file (`/var` is a link to `/private/var`); and a hard link is a regular file.
/// - **The payload is mapped, not copied** (#98). `payload(of:)` maps the payload from the descriptor it opened as
///   a private copy-on-write mapping (`mmap`, `PROT_READ | PROT_WRITE`, `MAP_PRIVATE`; the descriptor itself is read
///   only) and never copies it into memory, so a large item does not count toward the app's memory (clean
///   file-backed pages). A write to the `Data`, even in place, goes to a private copy of that page and never reaches
///   the file; with `PROT_READ` alone, an in-place write would crash (review of #106). The mapping stays valid after
///   the descriptor is closed and after the item is removed, and keeps the removed payload's disk space allocated
///   until the `Data` is released, which unmaps it. Limits, accepted because they need write access to the group
///   (outside the threat model of #85): a payload changed or truncated by another process while it is mapped may
///   crash the reader or give it bytes that differ from the file's bytes at the open, and then the hash, PDFKit's
///   check and the stored bytes may disagree with each other (probes of #98: a truncated mapping read stale or zero
///   bytes and raised no signal, on macOS and on iOS). The app counts an attempt before it reads, so an item that
///   crashes it moves to `Failed/` after `maxAttempts`. The writer's copy has no such limit: `read(2)` of a truncated
///   file returns short and never raises a signal. Mapping also relies on the group container having no data protection
///   that locks files (`NSFileProtectionComplete`): a page fault on such a file after the device locks would crash the
///   reader,
///   where a `read` returns an error.
/// - **Versions.** An `item.json` with a newer `version` (a newer extension than app) is left alone; one that
///   cannot be read moves to `Failed/`.
/// - **Attempts.** The reader counts an attempt in `item.json` before it imports an item (a new file in the item's
///   folder, written in full and synced, then renamed over `item.json`); at `maxAttempts` the item moves to
///   `Failed/`.
///
/// Foundation and the C library only (Darwin, Glibc or Musl), so it is tested on Linux. Every method works on the
/// file system directly and is safe to call from any thread; two processes may use one queue at the same time.
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
    /// the item's identifier. The item appears in `Items/` complete or not at all. `source` is opened once, without
    /// following a link at its last component, and copied from the open file through one 1 MiB buffer, so memory
    /// stays bounded whatever the file's size. Throws, and writes nothing:
    /// - when `source` cannot be opened as a regular file, the open's error: `NotARegularFile` when it is a symbolic
    ///   link, a folder, a FIFO, a socket, a device or anything else that is not a regular file, `POSIXError(.ENOENT)`
    ///   when it does not exist, another `POSIXError` (such as `EACCES`) when it cannot be opened;
    /// - once it was opened, `CopyFailed` for every failure: reading it, or writing the queue (`ENOSPC`, `EDQUOT`,
    ///   `EIO`, the folders, `item.json`, the rename). The share extension then does not fall back to the data
    ///   (`fallsBackToData(afterFileError:)`; #104, the maintainer's decision P1 = A).
    @discardableResult
    public func add(
        copyingFileAt source: URL, originalFileName: String, typeIdentifier: String, createdAt: Date = Date()
    ) throws -> UUID {
        try add(
            copyingFileAt: source, originalFileName: originalFileName, typeIdentifier: typeIdentifier,
            createdAt: createdAt, afterOpen: nil)
    }

    /// `add(copyingFileAt:…)` with hooks for tests: `afterOpen` runs after `source` was opened and checked, and the
    /// copy writes through `writeCall` (as `writeAll` does).
    @discardableResult
    func add(
        copyingFileAt source: URL, originalFileName: String, typeIdentifier: String, createdAt: Date,
        afterOpen: (() throws -> Void)?, writeCall: WriteCall = { write($0, $1, $2) }
    ) throws -> UUID {
        let input = try Self.openRegularFile(source)
        defer { try? input.close() }
        // From here on the lent file is open: any failure is `CopyFailed`, which never falls back to the data.
        do {
            try afterOpen?()
            return try add(originalFileName: originalFileName, typeIdentifier: typeIdentifier, createdAt: createdAt) {
                try Self.copy(from: input, to: $0, using: writeCall)
            }
        } catch {
            throw CopyFailed(underlying: error)
        }
    }

    /// A file to copy, or a file of an item to read, that is not a regular file (a symbolic link, a folder, a FIFO,
    /// a device), or an item folder that is not a real folder.
    public struct NotARegularFile: Error, Equatable {
        public init() {}
    }

    /// `add(copyingFileAt:…)` failed after the lent file was opened as a regular file: reading it or writing the
    /// queue (`ENOSPC`, `EDQUOT`, `EIO`, the folders, `item.json`, the rename); `underlying` is that error. Nothing
    /// was written. The share extension does not fall back to the data after it (#104, the maintainer's decision
    /// P1 = A): the data would go to the same full or failing volume, and loading it holds the whole attachment in
    /// the extension's memory.
    public struct CopyFailed: Error {
        public let underlying: any Error

        public init(underlying: any Error) {
            self.underlying = underlying
        }
    }

    /// Whether the share extension may load the attachment's data (`loadDataRepresentation`) after the lent file
    /// could not be copied with `add(copyingFileAt:…)`; `error` is what that threw, `nil` when no file was lent.
    /// Only when no file was lent or the lent file could not be opened (`POSIXError(.ENOENT)` for a file that is
    /// gone, `EACCES`, and the like). Never after `NotARegularFile`: a lent symbolic link, folder, FIFO, socket or
    /// device is not saved, so the extension never reads through a link (#87, the maintainer's decision on P1).
    /// Never after `CopyFailed`: once the lent file was opened, a failure ends the attachment unsaved (#104, the
    /// maintainer's decision P1 = A).
    public static func fallsBackToData(afterFileError error: (any Error)?) -> Bool {
        !(error is NotARegularFile) && !(error is CopyFailed)
    }

    /// What the share extension's file step did for one attachment (`saveAttachment`).
    public enum FileStep: Sendable {
        /// The lent file is in the queue.
        case saved
        /// Not saved; the error is what `add(copyingFileAt:…)` threw, `nil` when no file was lent.
        case notSaved((any Error)?)
    }

    /// The share extension's order for one attachment (#104): `savingFile` (the lent file, copied with
    /// `add(copyingFileAt:…)`), then `savingData` (`loadDataRepresentation`, then `add(data:…)`) only when the file
    /// step did not save it and `fallsBackToData(afterFileError:)` allows it: no file lent, or a lent file that could
    /// not be opened. Never after `NotARegularFile` or `CopyFailed`. Each closure runs at most once, one after the
    /// other, in the caller's isolation (`nonisolated(nonsending)`): the closures never leave it, so they may capture
    /// what is not `Sendable` (the extension builds with `NonisolatedNonsendingByDefault`, this package does not).
    /// - Returns: whether the attachment was saved.
    public nonisolated(nonsending) static func saveAttachment(
        savingFile: nonisolated(nonsending) () async -> FileStep,
        savingData: nonisolated(nonsending) () async -> Bool
    ) async -> Bool {
        switch await savingFile() {
        case .saved:
            return true
        case .notSaved(let error):
            guard fallsBackToData(afterFileError: error) else { return false }
            return await savingData()
        }
    }

    /// Adds `data` as an item; see `add(copyingFileAt:…)`.
    @discardableResult
    public func add(data: Data, originalFileName: String, typeIdentifier: String, createdAt: Date = Date()) throws
        -> UUID
    {
        try add(
            data: data, originalFileName: originalFileName, typeIdentifier: typeIdentifier, createdAt: createdAt,
            beforeHandOver: nil)
    }

    /// `add(data:…)` with a hook for tests: `beforeHandOver` gets the finished item's folder right before the
    /// rename into `Items/`.
    func add(
        data: Data, originalFileName: String, typeIdentifier: String, createdAt: Date = Date(),
        beforeHandOver: ((URL) throws -> Void)? = nil
    ) throws -> UUID {
        try add(
            originalFileName: originalFileName, typeIdentifier: typeIdentifier, createdAt: createdAt,
            beforeHandOver: beforeHandOver
        ) {
            try data.write(to: $0)
        }
    }

    private func add(
        originalFileName: String, typeIdentifier: String, createdAt: Date,
        beforeHandOver: ((URL) throws -> Void)? = nil, writePayload: (URL) throws -> Void
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
            try Self.writeInfo(info, to: building)
            try fileManager.createDirectory(at: itemsFolder, withIntermediateDirectories: true)
            try beforeHandOver?(building)
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
            // A link or a file among the item folders is not an item the writer made.
            let entryType = try? fileManager.attributesOfItem(atPath: itemsFolder.appending(path: name).path)[.type]
            guard let id = UUID(uuidString: name), entryType as? FileAttributeType == .typeDirectory else {
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

    /// Counts one attempt in the item's `item.json` (atomically) and returns the item as written. Everything goes
    /// through the item folder's descriptor: a new file in that folder, written in full and synced, then renamed
    /// over `item.json`. Throws, and writes nothing, when the item cannot be written; the caller then leaves it
    /// for the next run: `NotARegularFile` when the item's folder is not a real folder (a link to one),
    /// `POSIXError(.ENOENT)` when the item is gone, `CocoaError(.fileNoSuchFile)` when its `item.json` is missing
    /// or not a regular file.
    public func recordAttempt(_ item: ShareQueueItem) throws -> ShareQueueItem {
        try recordAttempt(item, beforeReplace: nil)
    }

    /// `recordAttempt(_:)` with a hook for tests: `beforeReplace` runs after the folder was opened and `item.json`
    /// was checked, right before the new file is written.
    func recordAttempt(_ item: ShareQueueItem, beforeReplace: (() throws -> Void)?) throws -> ShareQueueItem {
        var info = item.info
        info.attempts += 1
        let folder = try Self.openFolder(itemFolder(item.id))
        defer { close(folder) }
        var status = stat()
        let found = Self.call(Self.infoName) { fstatat(folder, $0, &status, AT_SYMLINK_NOFOLLOW) }
        guard found.result == 0, status.st_mode & S_IFMT == S_IFREG else { throw CocoaError(.fileNoSuchFile) }
        try beforeReplace?()
        try Self.replace(Self.infoName, in: folder, with: Self.encode(info))
        return ShareQueueItem(id: item.id, info: info)
    }

    /// Where the item's bytes are.
    public func payloadURL(of item: ShareQueueItem) -> URL {
        itemFolder(item.id).appending(path: Self.payloadName)
    }

    /// The item's bytes, mapped copy-on-write from the payload opened once through the item folder's descriptor (never
    /// through a link, out of the queue), never copied into memory (#98; see the type's "The payload is mapped").
    /// Writing to the `Data` changes private pages only, never the file. The `Data` stays valid after the item is
    /// removed, and keeps the payload's disk space until it is released; an empty payload is empty `Data`. Throws
    /// `NotARegularFile` when the payload is not a regular file or the item's folder is not a real folder,
    /// `POSIXError(.ENOENT)` when either is missing, or the mapping's error.
    public func payload(of item: ShareQueueItem) throws -> Data {
        try payload(of: item, afterOpen: nil)
    }

    /// `payload(of:)` with a hook for tests: `afterOpen` runs after the payload was opened and checked.
    func payload(of item: ShareQueueItem, afterOpen: (() throws -> Void)?) throws -> Data {
        let folder = try Self.openFolder(itemFolder(item.id))
        defer { close(folder) }
        let payload = try Self.openRegularFile(named: Self.payloadName, in: folder)
        defer { try? payload.close() }
        try afterOpen?()
        return try Self.map(payload)
    }

    /// The whole of the open `file`, mapped copy-on-write (`PROT_READ | PROT_WRITE`, `MAP_PRIVATE`: `Data` writes in
    /// place into a uniquely referenced buffer, and a write must reach a private page, never the file or a fault)
    /// and unmapped when the `Data` is released; the mapping outlives `file`. Empty `Data` for an empty file (`mmap`
    /// of length 0 is `EINVAL`).
    static func map(_ file: FileHandle) throws -> Data {
        var status = stat()
        guard fstat(file.fileDescriptor, &status) == 0 else { throw posixError(errno) }
        let size = Int(status.st_size)
        guard size > 0 else { return Data() }
        // `MAP_FAILED` is `(void *)-1` on every platform.
        guard let mapped = mmap(nil, size, PROT_READ | PROT_WRITE, MAP_PRIVATE, file.fileDescriptor, 0),
            mapped != UnsafeMutableRawPointer(bitPattern: -1)
        else { throw posixError(errno) }
        return Data(bytesNoCopy: mapped, count: size, deallocator: .custom { _ = munmap($0, $1) })
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

    /// The name the share extension gives an item (the rule of #85, round 2), as data (`fileName(fromShared:)`):
    /// - the suggested name, else the lent file's name;
    /// - a name that would give an empty title (none, or only an extension such as ".pdf") is replaced by the
    ///   share's date and time, `yyyy-MM-dd HH:mm`, keeping its extension;
    /// - the type's preferred extension is added only when the name has no extension of an importable type
    ///   (`isImportableExtension`: a PDF or an image type). "Rechnung 2024.03" becomes "Rechnung 2024.03.pdf", so
    ///   the title keeps ".03"; "scan.jpg" stays "scan.jpg" when the bytes are HEIC, and "photo.png" stays when they
    ///   are JPEG: the importer goes by the item's type, the name only gives the title.
    public static func itemFileName(
        suggested: String?, lentFileName: String?, preferredExtension: String?, date: Date,
        timeZone: TimeZone = .current, isImportableExtension: (String) -> Bool
    ) -> String {
        let candidates = [suggested, lentFileName].compactMap { $0.map(fileName(fromShared:)) }
        var name = candidates.first { !$0.isEmpty } ?? ""
        let pathExtension = Self.pathExtension(of: name)
        if importTitle(fromFileName: name).isEmpty {
            name = fallbackName(date: date, timeZone: timeZone) + (pathExtension.map { ".\($0)" } ?? "")
        }
        if let current = pathExtension, isImportableExtension(current.lowercased()) { return name }
        guard let preferredExtension, !preferredExtension.isEmpty else { return name }
        return "\(name).\(preferredExtension)"
    }

    /// The part after the last dot, when it is one (not empty, no whitespace), as `importTitle` sees it.
    static func pathExtension(of name: String) -> String? {
        guard let dot = name.lastIndex(of: ".") else { return nil }
        let part = String(name[name.index(after: dot)...])
        return part.isEmpty || part.contains(where: \.isWhitespace) ? nil : part
    }

    /// `yyyy-MM-dd HH:mm` in `timeZone`, the same in every language.
    static func fallbackName(date: Date, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
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

    /// Reads `item.json` through the folder's descriptor; a link or anything but a regular file is unreadable.
    private static func readInfo(in folder: URL) -> ReadInfo {
        guard let directory = try? openFolder(folder) else { return .unreadable }
        defer { close(directory) }
        guard let file = try? openRegularFile(named: infoName, in: directory) else { return .unreadable }
        defer { try? file.close() }
        guard let data = try? file.readToEnd() else { return .unreadable }
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

    private static func encode(_ info: ShareQueueItem.Info) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(info)
    }

    /// The writer's `item.json` in its own new `Incoming/<UUID>/` folder.
    private static func writeInfo(_ info: ShareQueueItem.Info, to folder: URL) throws {
        // Atomic: the reader rewrites it to count attempts, and a crash must not leave half a file.
        try encode(info).write(to: folder.appending(path: infoName), options: .atomic)
    }

    // MARK: Opening files (once, never through a link)

    /// A regular file: read only, never through a link (the last component), and never blocking, so a FIFO cannot
    /// hang the open; whether it is a regular file is checked on the open descriptor.
    static let readFlags = O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC
    /// An item's folder: only a real folder, never a link to one.
    static let folderFlags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
    /// A new file of our own: created here or not at all, never through a link.
    static let newFileFlags = O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC
    /// The copy reads and writes this much at a time, so the extension's memory stays bounded.
    static let copyChunkSize = 1 << 20

    /// Opens `url` once, only when it is itself a regular file (`readFlags`, then `fstat`).
    static func openRegularFile(_ url: URL) throws -> FileHandle {
        let opened = try call(url) { open($0, readFlags) }
        return try regularFile(opened)
    }

    /// `openRegularFile` for the entry `name` of an open folder (`openat`).
    static func openRegularFile(named name: String, in folder: Int32) throws -> FileHandle {
        try regularFile(call(name) { openat(folder, $0, readFlags) })
    }

    /// Opens an item's folder only when it is itself a folder, not a link to one. The caller closes it.
    static func openFolder(_ url: URL) throws -> Int32 {
        let opened = try call(url) { open($0, folderFlags) }
        guard opened.result >= 0 else { throw openError(opened.code) }
        return opened.result
    }

    private static func regularFile(_ opened: (result: Int32, code: Int32)) throws -> FileHandle {
        guard opened.result >= 0 else { throw openError(opened.code) }
        var status = stat()
        guard fstat(opened.result, &status) == 0, status.st_mode & S_IFMT == S_IFREG else {
            close(opened.result)
            throw NotARegularFile()
        }
        return FileHandle(fileDescriptor: opened.result, closeOnDealloc: true)
    }

    /// Copies the open `input` into a new file at `destination` with `read(2)` and `write(2)` through one reused
    /// buffer of `copyChunkSize`, then `fsync`. Memory stays at one buffer whatever the file's size, on every
    /// platform: no chunk becomes a `Data` (on Apple platforms `FileHandle.read(upToCount:)` returns autoreleased
    /// data, and a loop without a pool keeps every chunk until it returns; review of #95, B1).
    private static func copy(from input: FileHandle, to destination: URL, using writeCall: WriteCall) throws {
        let created = try call(destination) { open($0, newFileFlags, 0o644) }
        guard created.result >= 0 else { throw posixError(created.code) }
        let output = created.result
        defer { close(output) }
        let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: copyChunkSize, alignment: 16)
        defer { buffer.deallocate() }
        while true {
            let count = read(input.fileDescriptor, buffer.baseAddress, buffer.count)
            if count == 0 { break }
            if count < 0 {
                let code = errno
                if code == EINTR { continue }
                throw posixError(code)
            }
            try writeAll(UnsafeRawBufferPointer(rebasing: buffer[..<count]), to: output, using: writeCall)
        }
        guard fsync(output) == 0 else { throw posixError(errno) }
    }

    /// `write(2)`, as `writeAll` calls it; a test passes one that writes short or fails.
    typealias WriteCall = (_ descriptor: Int32, _ bytes: UnsafeRawPointer, _ count: Int) -> Int

    /// Writes all of `bytes` to `descriptor`: loops on short writes and on `EINTR`, throws any other error (N8).
    static func writeAll(
        _ bytes: UnsafeRawBufferPointer, to descriptor: Int32, using writeCall: WriteCall = { write($0, $1, $2) }
    ) throws {
        guard var next = bytes.baseAddress else { return }
        var left = bytes.count
        while left > 0 {
            let written = writeCall(descriptor, next, left)
            if written < 0 {
                let code = errno
                if code == EINTR { continue }
                throw posixError(code)
            }
            guard written > 0 else { throw posixError(EIO) }
            next += written
            left -= written
        }
    }

    /// Replaces the entry `name` of an open folder with `data`, atomically: a new file in that folder (`O_EXCL`,
    /// never through a link), written in full and synced, then renamed over `name` in the same folder. The new file
    /// is removed again on any error.
    private static func replace(_ name: String, in folder: Int32, with data: Data) throws {
        let temporary = ".\(name).\(UUID().uuidString)"
        let created = call(temporary) { openat(folder, $0, newFileFlags, 0o644) }
        guard created.result >= 0 else { throw posixError(created.code) }
        do {
            let file = created.result
            defer { close(file) }
            try data.withUnsafeBytes { try writeAll($0, to: file) }
            guard fsync(file) == 0 else { throw posixError(errno) }
            let renamed = temporary.withCString { from in
                name.withCString { to in
                    let result = renameat(folder, from, folder, to)
                    return (result: result, code: result < 0 ? errno : 0)
                }
            }
            guard renamed.result == 0 else { throw posixError(renamed.code) }
        } catch {
            _ = call(temporary) { unlinkat(folder, $0, 0) }
            throw error
        }
    }

    /// Runs `body` on `url`'s file-system path and returns its result with the `errno` it left, read inside the
    /// closure. A URL without a file-system path throws `CocoaError(.fileReadInvalidFileName)`.
    private static func call(_ url: URL, _ body: (UnsafePointer<CChar>) -> Int32) throws -> (
        result: Int32, code: Int32
    ) {
        let outcome: (result: Int32, code: Int32)? = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return nil }
            let result = body(path)
            return (result, result < 0 ? errno : 0)
        }
        guard let outcome else { throw CocoaError(.fileReadInvalidFileName) }
        return outcome
    }

    /// Runs `body` on `name` as a C string and returns its result with the `errno` it left, read inside the closure.
    private static func call(_ name: String, _ body: (UnsafePointer<CChar>) -> Int32) -> (result: Int32, code: Int32) {
        name.withCString { name in
            let result = body(name)
            return (result, result < 0 ? errno : 0)
        }
    }

    /// The error of a failed open. `NotARegularFile` for what is not a regular file but cannot be opened at all: a
    /// link (`ELOOP`; Linux gives `ENOTDIR` for a link opened with `O_DIRECTORY`) and a socket (`EOPNOTSUPP` on
    /// Apple platforms, `ENXIO` on Linux). Anything else is its `POSIXError`, such as `ENOENT` for a missing file.
    private static func openError(_ code: Int32) -> any Error {
        [ELOOP, ENOTDIR, EOPNOTSUPP, ENXIO].contains(code) ? NotARegularFile() : posixError(code)
    }

    private static func posixError(_ code: Int32) -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
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
