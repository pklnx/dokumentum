import DokumentumKit
import Foundation
import SwiftData

/// The one-time re-queue of documents that step 3 processed without text (#6, part 2; plan point 6, T6, N7): every
/// `Document` that is `done` with `textSource == .none` goes back to `pending`, **with this device's claim**
/// (`processingDeviceID`, `processingClaimedAt = now`), so this device processes it at once and the other device
/// waits for the claim instead of taking it over. Trashed documents are included; they wait for a restore.
///
/// Per device, behind a flag in the per-device `UserDefaults` (`flagKey`, never synced). The processing queue runs
/// it at the start of each run until one pass completed without a write that backed off or failed; then it sets the
/// flag and never runs again. Both devices may run it: a document the other device already re-queued is `pending`,
/// one it already processed has `.pdfText` or `.vision`, and both fail the re-check here. If both write before they
/// sync, the claims race as any two claims do, and the exact-claim result write keeps one result.
///
/// Each document is one write under the queue's write discipline (T6): a fresh context fetches it, re-checks `done`
/// and `.none` (nothing written otherwise), sets the three fields, reads the row again in a second context
/// (`RowState.read`) and saves only when every field is unchanged. The scan reads only `Document` rows.
///
/// It also records the documents it re-queued that have no thumbnail (`thumbnailBackfillKey`): step 5's thumbnail
/// backfill (#6, part 4) renders one only for those, so a document imported by a newer build is never backfilled
/// (N3). The link is read from the document row, without loading a blob.
public struct ProcessingRequeue: Sendable {
    /// Set once this device's pass completed.
    public static let flagKey = "processingRequeue.textV1"
    /// The `instanceID`s of re-queued documents without a thumbnail, for part 4's backfill.
    public static let thumbnailBackfillKey = "processingRequeue.thumbnailBackfill"

    /// What one pass did.
    public struct Report: Equatable, Sendable {
        /// Documents set back to `pending` with this device's claim.
        public var requeued = 0
        /// Documents whose row changed since the scan (no longer `done` or `.none`, or gone): nothing written.
        public var changed = 0
        /// Writes whose check found the row changed by another save: rolled back; the next run's pass tries again.
        public var backedOff = 0
        /// Writes the store refused (logged); the next run's pass tries again.
        public var failed = 0
        /// Whether the pass completed and set the flag.
        public var completed = false

        public init() {}
    }

    /// The `UserDefaults` suite; `nil` is `UserDefaults.standard`.
    public let defaultsSuite: String?

    public init(defaultsSuite: String?) {
        self.defaultsSuite = defaultsSuite
    }

    private var defaults: UserDefaults {
        defaultsSuite.flatMap(UserDefaults.init(suiteName:)) ?? .standard
    }

    /// Whether this device's pass completed.
    public var isDone: Bool { defaults.bool(forKey: Self.flagKey) }

    /// The documents recorded for the thumbnail backfill.
    public var thumbnailBackfill: Set<UUID> {
        Set((defaults.stringArray(forKey: Self.thumbnailBackfillKey) ?? []).compactMap(UUID.init(uuidString:)))
    }

    private func record(forThumbnail documents: Set<UUID>) {
        guard !documents.isEmpty else { return }
        let all = thumbnailBackfill.union(documents)
        defaults.set(all.map(\.uuidString).sorted(), forKey: Self.thumbnailBackfillKey)
    }

    /// One pass, unless the flag is set. Synchronous: each write runs without a suspension.
    /// - Parameter beforeCheck: tests only; runs in each write after its fields were set and before the check reads
    ///   the row again, where a test saves another context's edit.
    @discardableResult
    public func run(
        in container: ModelContainer, deviceID: String, now: Date,
        beforeCheck: (@Sendable () throws -> Void)? = nil
    ) -> Report {
        var report = Report()
        guard !isDone else { return report }
        let candidates: [UUID]
        do {
            candidates = try Self.scan(in: container)
        } catch {
            Log.processing.error("Re-queue scan failed: \(Log.code(of: error), privacy: .public)")
            report.failed += 1
            return report
        }
        var withoutThumbnail: Set<UUID> = []
        for id in candidates {
            switch Self.requeue(id, deviceID: deviceID, now: now, in: container, beforeCheck: beforeCheck) {
            case .saved(let hasThumbnail):
                report.requeued += 1
                if !hasThumbnail { withoutThumbnail.insert(id) }
            case .changed: report.changed += 1
            case .metAnotherSave: report.backedOff += 1
            case .failed: report.failed += 1
            }
        }
        record(forThumbnail: withoutThumbnail)
        if report.backedOff == 0, report.failed == 0 {
            defaults.set(true, forKey: Self.flagKey)
            report.completed = true
        }
        Log.processing.notice(
            """
            Re-queue pass: requeued \(report.requeued, privacy: .public), changed \(report.changed, privacy: .public), \
            backed off \(report.backedOff, privacy: .public), failed \(report.failed, privacy: .public), completed \
            \(report.completed, privacy: .public)
            """)
        return report
    }

    /// The documents that are `done` with `textSource == .none`, oldest first, one per `instanceID`: only
    /// `Document` rows.
    static func scan(in container: ModelContainer) throws -> [UUID] {
        let done = ProcessingState.done.storedValue ?? "done"
        let none = TextSource.none.storedValue ?? ""
        let descriptor = FetchDescriptor<Document>(
            predicate: #Predicate { $0.processingStateRaw == done && $0.textSourceRaw == none })
        var seen: Set<UUID> = []
        return RowRecords.oldestFirst(try ModelContext(container).fetch(descriptor)).map(\.instanceID).filter {
            seen.insert($0).inserted
        }
    }

    enum Outcome: Equatable {
        case saved(hasThumbnail: Bool)
        case changed, metAnotherSave, failed
    }

    /// One document's write, steps 1 to 5 of the discipline.
    static func requeue(
        _ id: UUID, deviceID: String, now: Date, in container: ModelContainer,
        beforeCheck: (@Sendable () throws -> Void)?
    ) -> Outcome {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        do {
            guard let document = try ProcessingQueue.fetch(id, in: context), document.processingState == .done,
                document.textSource == .none
            else { return .changed }
            let read = RowState.capture(document)
            let hasThumbnail = document.thumbnail != nil
            document.processingState = .pending
            document.processingDeviceID = deviceID
            document.processingClaimedAt = now
            try beforeCheck?()
            let key = RowKey(entity: .document, instanceID: id)
            guard try RowState.read([key], in: container)[key] == read else {
                context.rollback()
                Log.processing.notice("A re-queue write met another save of its document and wrote nothing")
                return .metAnotherSave
            }
            try context.save()
            return .saved(hasThumbnail: hasThumbnail)
        } catch {
            context.rollback()
            Log.processing.error("A re-queue write failed: \(Log.code(of: error), privacy: .public)")
            return .failed
        }
    }
}
