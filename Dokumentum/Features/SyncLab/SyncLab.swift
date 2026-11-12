#if DEBUG
    import DokumentumCore
    import DokumentumKit
    import Foundation
    import Observation
    import SwiftData

    /// The Sync lab (plan of #31, part 2, Approach 3): the maintainer's tool for the two-device protocol
    /// (`docs/development/sync.md`). Debug builds only; Release builds do not contain it. One per app, created next to
    /// the store; the Mac's Debug menu opens it in a window of its own, the iPhone's debug toolbar menu as a sheet.
    ///
    /// It writes through the real code paths: the app's importer, `DocumentEditor`, `DocumentTrash`, the scheduler's
    /// hold, the repair and the search index. Only `SyncLabActions` bypasses them, on lab documents only. On a store on
    /// disk, the first write of a session asks first, as "Add Sample Documents" does.
    @MainActor
    @Observable
    final class SyncLab {
        let container: ModelContainer
        let launchStore: LaunchStore
        let deviceID: String
        @ObservationIgnored let importer: any DocumentImporting
        @ObservationIgnored let processing: ProcessingScheduler?
        @ObservationIgnored let repair: RepairScheduler?
        @ObservationIgnored let search: SearchIndexer
        let monitor: CloudSyncMonitor?
        /// The takeover interval in effect: `-ProcessingTakeoverSeconds`, else 6 hours.
        let takeoverInterval: TimeInterval
        /// The defaults suite of the per-device values; `nil` is the app's.
        let defaultsSuite: String?

        /// The documents as the list shows them; `nil` before the first read.
        private(set) var rows: [SyncLabDocuments.Row]?
        private(set) var metadata = SyncLabDocuments.Metadata()
        /// Large values of the documents whose details were asked for.
        private(set) var details: [UUID: SyncLabDocuments.Details] = [:]
        /// The unique word of the last document the lab created.
        private(set) var lastWord: String?
        /// The last action's outcome, shown at the top.
        private(set) var message: String?
        /// Whether a create, an export or the schema initialization is going on.
        private(set) var isBusy = false
        private(set) var dump: SyncLabExport.Dump?
        private(set) var searchAnswer: String?
        /// Whether the first write of this session waits for the confirmation.
        var isConfirmingWrite = false
        @ObservationIgnored private var pendingWrite: (@MainActor () async -> Void)?
        private var hasConfirmedWrites = false
        /// Called on the main actor after each write that ran (confirmed or without a question). For tests, which
        /// wait for it instead of polling.
        @ObservationIgnored var didFinishWrite: (@MainActor () -> Void)?

        init(
            container: ModelContainer, launchStore: LaunchStore, deviceID: String, importer: any DocumentImporting,
            processing: ProcessingScheduler?, repair: RepairScheduler?, search: SearchIndexer,
            monitor: CloudSyncMonitor?, takeoverInterval: TimeInterval?, defaultsSuite: String? = nil
        ) {
            self.container = container
            self.launchStore = launchStore
            self.deviceID = deviceID
            self.importer = importer
            self.processing = processing
            self.repair = repair
            self.search = search
            self.monitor = monitor
            self.takeoverInterval = takeoverInterval ?? ProcessingClaimRules.takeoverInterval
            self.defaultsSuite = defaultsSuite
            refreshDeviceSettings()
        }

        var shortDeviceID: String { String(deviceID.prefix(8)) }

        /// Whether the first write of a session asks first: every store on disk (`LaunchStore`).
        var asksBeforeWriting: Bool { launchStore.asksBeforeAddingSampleDocuments }

        // MARK: Writes and the confirmation

        /// Runs `write` now, or after the confirmation for the first write of a session on a store on disk.
        func perform(_ write: @escaping @MainActor () async -> Void) {
            if asksBeforeWriting, !hasConfirmedWrites {
                pendingWrite = write
                isConfirmingWrite = true
                return
            }
            run(write)
        }

        func confirmWrites() {
            hasConfirmedWrites = true
            isConfirmingWrite = false
            let write = pendingWrite
            pendingWrite = nil
            if let write { run(write) }
        }

        private func run(_ write: @escaping @MainActor () async -> Void) {
            Task {
                await write()
                didFinishWrite?()
            }
        }

        /// Whether the lab may change this device's settings (the re-queue flag, the classification switch): only
        /// with a store on disk. An in-memory store (UI tests, screenshots) runs with the app's own defaults, so a
        /// change there would reach the next real launch of this Mac or simulator without a question.
        var canChangeDeviceSettings: Bool { asksBeforeWriting }

        func cancelWrite() {
            isConfirmingWrite = false
            pendingWrite = nil
        }

        private func report(_ text: String) {
            message = text
        }

        private func report(_ error: any Error, _ what: String) {
            if let refusal = error as? SyncLabActions.Refusal {
                message = "\(what) refused: \(refusal)"
            } else {
                message = "\(what) failed: \(Log.code(of: error))"
            }
        }

        // MARK: Create

        /// Names for a new text document: tags (comma-separated), correspondent and type, each with the lab prefix.
        struct Names {
            var tags = ""
            var correspondent = ""
            var documentType = ""
        }

        /// Creates a lab document of `kind`; with `letter` (text and scan-like only), page 1 reads like a letter, for
        /// the classification cases M1/M2.
        func create(_ kind: SyncLabGenerator.Kind, pages: Int, names: Names, letter: Bool = false) {
            perform { [self] in
                isBusy = true
                defer { isBusy = false }
                let word = SyncLabGenerator.uniqueWord()
                let outcome: ImportOutcome
                switch kind {
                case .text:
                    outcome = await SyncLabGenerator.importText(
                        word: word, pages: pages, letter: letter, importer: importer)
                case .scan:
                    outcome = await SyncLabGenerator.importScan(
                        word: word, pages: pages, letter: letter, importer: importer)
                case .large:
                    outcome = await SyncLabGenerator.importLarge(
                        word: word, bytes: SyncLabGenerator.largeFileBytes, importer: importer)
                case .legacy:
                    do {
                        let id = try SyncLabActions.insertLegacyDocument(
                            in: container, deviceID: deviceID, word: word, pages: pages)
                        outcome = .imported(instanceID: id)
                    } catch {
                        report(error, "Legacy document")
                        return
                    }
                }
                guard case .imported(let instanceID) = outcome else {
                    report("\(kind.label) not imported: \(outcome)")
                    return
                }
                lastWord = word
                if kind == .text { assign(names, to: instanceID) }
                report("\(kind.label) created: \(word)")
                await refresh()
            }
        }

        /// Assigns tags, correspondent and type by name through `DocumentEditor`, creating them if missing.
        private func assign(_ names: Names, to instanceID: UUID) {
            let editor = DocumentEditor(context: container.mainContext)
            do {
                for name in names.tags.split(separator: ",").map(String.init)
                where !name.trimmingCharacters(in: .whitespaces).isEmpty {
                    let tag = try editor.createMetadata(kind: .tag, name: SyncLabActions.labName(name))
                    try editor.apply(.tag(tag, true), to: instanceID)
                }
                if !names.correspondent.trimmingCharacters(in: .whitespaces).isEmpty {
                    let id = try editor.createMetadata(
                        kind: .correspondent, name: SyncLabActions.labName(names.correspondent))
                    try editor.apply(.correspondent(id), to: instanceID)
                }
                if !names.documentType.trimmingCharacters(in: .whitespaces).isEmpty {
                    let id = try editor.createMetadata(
                        kind: .documentType, name: SyncLabActions.labName(names.documentType))
                    try editor.apply(.documentType(id), to: instanceID)
                }
            } catch {
                report(error, "Metadata")
            }
        }

        // MARK: Documents

        func refresh() async {
            refreshDeviceSettings()
            do {
                rows = try await SyncLabDocuments.rows(in: container)
                metadata = try await SyncLabDocuments.metadata(in: container)
            } catch {
                report(error, "Reading the documents")
            }
        }

        func loadDetails(_ instanceID: UUID) async {
            do {
                details[instanceID] = try await SyncLabDocuments.details(of: instanceID, in: container)
            } catch {
                report(error, "Reading the details")
            }
        }

        /// One edit through `DocumentEditor`, as the library makes it.
        func edit(_ change: DocumentEditor.Change, of instanceID: UUID) {
            perform { [self] in
                do {
                    let outcome = try DocumentEditor(context: container.mainContext).apply(change, to: instanceID)
                    report("Edit: \(outcome)")
                } catch {
                    report(error, "Edit")
                }
                await refresh()
            }
        }

        /// Creates (or finds) a tag, correspondent or type with the lab prefix, and with a document links it to it.
        func editByName(_ kind: MetadataKind, name: String, add: Bool, of instanceID: UUID) {
            perform { [self] in
                let editor = DocumentEditor(context: container.mainContext)
                do {
                    let id = try editor.createMetadata(kind: kind, name: SyncLabActions.labName(name))
                    let change: DocumentEditor.Change =
                        switch kind {
                        case .tag: .tag(id, add)
                        case .correspondent: .correspondent(add ? id : nil)
                        case .documentType: .documentType(add ? id : nil)
                        }
                    report("Edit: \(try editor.apply(change, to: instanceID))")
                } catch {
                    report(error, "Edit")
                }
                await refresh()
            }
        }

        func trash(_ instanceID: UUID) {
            perform { [self] in
                do {
                    let moved = try DocumentTrash(context: container.mainContext).moveToTrash([instanceID])
                    report("Moved to the trash: \(moved.count)")
                } catch {
                    report(error, "Trash")
                }
                await refresh()
            }
        }

        func restore(_ instanceID: UUID) {
            perform { [self] in
                do {
                    let restored = try DocumentTrash(context: container.mainContext).restore([instanceID])
                    report("Restored: \(restored.count)")
                } catch {
                    report(error, "Restore")
                }
                await refresh()
            }
        }

        /// The trashed lab documents of `rows`: what the lab's "Empty trash" deletes. Trashed documents the lab did
        /// not create stay; only the app's own Empty Trash (with its count confirmation) deletes them.
        static func labTrash(of rows: [SyncLabDocuments.Row]) -> Set<UUID> {
            Set(rows.filter { $0.isTrashed && $0.isLabDocument }.map(\.instanceID))
        }

        /// Empties the trash of the **lab** documents the list shows as trashed, through `DocumentTrash` as the app's
        /// Empty Trash does. Other trashed documents stay (review A, B1 of PR #155).
        func emptyTrash() {
            perform { [self] in
                await refresh()
                let rows = rows ?? []
                let trashed = Self.labTrash(of: rows)
                let kept = Set(rows.filter(\.isTrashed).map(\.instanceID)).subtracting(trashed).count
                do {
                    let deleted = try DocumentTrash(context: container.mainContext).emptyTrash(confirmed: trashed)
                    report("Lab trash emptied: \(deleted.count); other trashed documents kept: \(kept)")
                } catch {
                    report(error, "Empty trash")
                }
                await refresh()
            }
        }

        /// Direct write 2 (S3), lab documents only.
        func deleteDirectly(_ instanceID: UUID) {
            perform { [self] in
                do {
                    try SyncLabActions.deleteDirectly(instanceID, in: container)
                    report("Deleted directly")
                } catch {
                    report(error, "Delete directly")
                }
                await refresh()
            }
        }

        /// Direct write 3 (C7), `done` lab documents only.
        func writeLargeText(_ instanceID: UUID, megabytes: Int) {
            perform { [self] in
                isBusy = true
                defer { isBusy = false }
                let word = SyncLabGenerator.uniqueWord()
                let container = container
                do {
                    // Megabytes of text: built and saved off the main actor.
                    let bytes = try await Task.detached {
                        try SyncLabActions.writeLargeText(instanceID, megabytes: megabytes, word: word, in: container)
                    }.value
                    lastWord = word
                    report("Large text written: \(bytes) bytes, word \(word)")
                } catch {
                    report(error, "Write large text")
                }
                details[instanceID] = nil
                await refresh()
            }
        }

        // MARK: Metadata

        func createMetadata(_ kind: MetadataKind, name: String) {
            perform { [self] in
                do {
                    _ = try DocumentEditor(context: container.mainContext).createMetadata(
                        kind: kind, name: SyncLabActions.labName(name))
                    report("Created \(kind): \(SyncLabActions.labName(name))")
                } catch {
                    report(error, "Create")
                }
                await refresh()
            }
        }

        /// Direct write 5 (C6), lab tags only.
        func moveTag(_ child: UUID, under parent: UUID?) {
            perform { [self] in
                do {
                    try SyncLabActions.moveTag(child, under: parent, in: container)
                    report("Tag moved")
                } catch {
                    report(error, "Move tag")
                }
                await refresh()
            }
        }

        // MARK: This device

        /// Whether this device's re-queue pass completed (`processingRequeue.textV1`).
        var isRequeueDone: Bool { ProcessingRequeue(defaultsSuite: defaultsSuite).isDone }

        /// Direct write 4 (R): clears this device's re-queue flag; the queue's next run makes the pass again. Only
        /// with a store on disk, after the question (`canChangeDeviceSettings`).
        func resetRequeueFlag() {
            guard canChangeDeviceSettings else {
                report("Reset re-queue flag: only with a store on disk")
                return
            }
            perform { [self] in
                SyncLabActions.resetRequeueFlag(defaultsSuite: defaultsSuite)
                report("Re-queue flag reset; relaunch (or the next run makes the pass)")
            }
        }

        /// Whether this device classifies (#8's per-device switch `classification.enabled`, on unless set; never
        /// synced). The protocol turns it off on both devices before run 1, so only M1/M2 classify (review A, B3 of
        /// PR #155). Read from the defaults at init and after each write of the lab, and observable, so the toggle
        /// shows the stored value once a confirmed write ran (review B, N3).
        private(set) var isClassificationEnabled = true

        /// Reads the device settings the lab shows again (the classification switch).
        func refreshDeviceSettings() {
            isClassificationEnabled = ClassificationSettings(defaultsSuite: defaultsSuite).isEnabled
        }

        /// Sets the classification switch (a device setting, not a data write; read at each decision, so the next
        /// run follows it). Only with a store on disk, after the question.
        func setClassification(_ enabled: Bool) {
            guard canChangeDeviceSettings else {
                report("Classification switch: only with a store on disk")
                return
            }
            perform { [self] in
                ClassificationSettings(defaultsSuite: defaultsSuite).isEnabled = enabled
                refreshDeviceSettings()
                Log.processing.notice("Sync lab: classification \(enabled ? "on" : "off", privacy: .public)")
                report("Classification on this device: \(enabled ? "on" : "off")")
                processing?.requestRun()
            }
        }

        /// Whether this lab holds the scheduler (the toggle's state; the scheduler itself is not observable).
        private(set) var isHeld = false

        /// "Hold processing on this device" (T14): no data write, in memory, ends with the process.
        func setHold(_ held: Bool) {
            guard let processing else { return }
            isHeld = held
            if held {
                processing.hold()
                Log.processing.notice("Sync lab: processing held")
            } else {
                processing.releaseHold()
                Log.processing.notice("Sync lab: processing hold released")
            }
        }

        /// The scheduler's state: held, paused, running or idle.
        var processingState: String {
            guard let processing else { return "no scheduler (in-memory store)" }
            var parts: [String] = []
            if processing.isHeld { parts.append("held") }
            if processing.isPaused { parts.append("paused") }
            parts.append(processing.isRunning ? "running" : "idle")
            return parts.joined(separator: ", ")
        }

        var lastProcessingReport: String {
            guard let report = processing?.lastReport else { return "no run yet" }
            return """
                done \(report.done), failed \(report.failed), failures \(report.failures), waiting \(report.waiting), \
                dropped \(report.dropped), backed off \(report.backedOff), interrupted \(report.interrupted), \
                requeued \(report.requeued), layered \(report.layered), classified \(report.classified), \
                capped \(report.textsCapped)
                """
        }

        var lastRepairCounts: String {
            guard let counts = repair?.lastReport?.counts else { return "no run yet" }
            return """
                orphans files \(counts.orphanFiles), thumbnails \(counts.orphanThumbnails), texts \(counts.orphanTexts); \
                two files \(counts.documentsWithTwoFiles), two thumbnails \(counts.documentsWithTwoThumbnails), \
                two texts \(counts.documentsWithTwoTexts); id duplicates \(counts.idGroupsWithSeveralRecords); \
                tombstones \(counts.tombstones)
                """
        }

        func runRepair() {
            repair?.requestRun()
            report(repair == nil ? "No repair for an in-memory store" : "Repair requested")
        }

        /// The "This device" section's periodic read (once a second): the device settings are read again, so the
        /// "Classification" line never shows a stale value after a change outside the lab (#8 part 3's switch; review
        /// B, N1 of round 2), and the search index's summary is returned.
        func refreshThisDevice() async -> String {
            refreshDeviceSettings()
            return await searchIndexSummary()
        }

        /// The search index's state, statistics and last history error.
        func searchIndexSummary() async -> String {
            let state = await search.state
            let statistics = await search.statistics
            let error = await search.lastHistoryErrorCode ?? "none"
            return """
                \(state), \(statistics.documents) documents, \(statistics.tokens) tokens, \
                \(statistics.postings) postings; last history error: \(error)
                """
        }

        // MARK: Search probe

        /// Searches as the library does (`SearchIndexer.search`) and names the hits by title.
        func probe(_ text: String) async {
            let result = await search.search(text)
            if rows == nil { await refresh() }
            let titles = (rows ?? []).filter { result.matches.contains($0.instanceID) }.map(\.title).sorted()
            let error = await search.lastHistoryErrorCode ?? "none"
            searchAnswer =
                "\(result.matches.count) hits (\(result.state)), last history error: \(error)"
                + (titles.isEmpty ? "" : "\n" + titles.joined(separator: "\n"))
        }

        // MARK: Export state

        func export(dates: SyncLabExport.DateRounding = .nearest) async {
            isBusy = true
            defer { isBusy = false }
            do {
                dump = try await SyncLabExport.build(container: container, defaultsSuite: defaultsSuite, dates: dates)
                report("Exported: \(dump?.hash.prefix(16) ?? "")")
            } catch {
                report(error, "Export state")
            }
        }

        // MARK: CloudKit schema

        /// Whether "Initialize CloudKit schema" can run: only with the CloudKit store (a signed build).
        var canInitializeSchema: Bool { launchStore.opened == .cloudKit }

        func initializeSchema() async {
            guard canInitializeSchema else { return }
            isBusy = true
            defer { isBusy = false }
            do {
                try await Self.runSchemaInitializer()
                report("CloudKit schema initialized in Development")
            } catch {
                report(error, "Initialize CloudKit schema")
            }
        }

        @concurrent
        private static func runSchemaInitializer() async throws {
            try DebugSchemaInitializer.run()
        }
    }
#endif
