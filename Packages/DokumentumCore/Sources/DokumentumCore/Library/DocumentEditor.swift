import DokumentumKit
import Foundation
import SwiftData

/// The one place that edits a document's metadata (plan of #3, part 3): title, document date, inbox flag,
/// correspondent, type and tags, on the document with a given `instanceID`, in the main context.
///
/// - **One field per edit.** CloudKit's last writer wins per field (#2, I6), so an edit writes only the field
///   that changed: setting a value the document already has writes nothing and does not save. A change sets
///   its field, calls `touch()` and saves once.
/// - **Gone or trashed documents are not edited.** A document deleted or moved to the trash meanwhile (on this
///   device or by sync) is left alone, and the edit reports why.
/// - **New metadata reuses what is there** (`createMetadata`): a live correspondent or type with the same
///   `MetadataName.normalized` name, a tag only with the same parent and normalized name, the key of the
///   repair's pass 2. Among several such records the first in `keeperOrder` is used, the one pass 2 keeps.
///   So the editor creates none of the duplicates pass 2 would merge later.
/// - **Deadlines** (#12, part 2a; plan §6): a new day is a new deadline, so it also sets `deadlineSetAt` and clears
///   `deadlineDoneAt` in the same save; a label edit or a done toggle writes only its own field and never rewrites
///   `deadlineDay` (review N8), so a suffix a later build appended to the day survives it. `deadlineDismissedDay` is
///   only ever raised: every write stores `max(stored, new)` (re-review N3), so two devices dismissing at once, or a
///   removal that dismisses, never bring back a day that was dismissed.
/// - **A failed save is rolled back.** Otherwise the change would stay pending in the main context, the library
///   would show it as saved, and the next edit's save (or an autosave) would write it after all.
@MainActor
public struct DocumentEditor {
    /// One edit of one field.
    public enum Change: Sendable, Equatable {
        /// The title, without the whitespace around it (`normalizedTitle`).
        case title(String)
        case documentDate(Date)
        case inbox(Bool)
        /// A live correspondent's `instanceID`, or `nil` for none.
        case correspondent(UUID?)
        /// A live document type's `instanceID`, or `nil` for none.
        case documentType(UUID?)
        /// Adds (`true`) or removes (`false`) the live tag with this `instanceID`. Removing it also removes the
        /// document's references to tombstones merged into it, which the library shows as that tag.
        case tag(UUID, Bool)
        /// Sets the deadline's day and label (#12), the label without the whitespace around it. A day other than the
        /// one the document reads is a new deadline: it also sets `deadlineSetAt` to now and clears `deadlineDoneAt`.
        /// The day it already reads writes only a changed label, and leaves the stored day string as it is.
        case deadline(DeadlineDay, label: String)
        /// Removes the deadline: empties `deadlineDay`, `deadlineLabel`, `deadlineSetAt` and `deadlineDoneAt`. With a
        /// day, the same save also dismisses due-date suggestions up to it (review N9: removing the deadline that a
        /// suggestion set must not offer it again), by the `max` rule.
        case clearDeadline(dismissing: DeadlineDay?)
        /// Marks the deadline done (`true`, `deadlineDoneAt` = now) or open again (`false`); writes only
        /// `deadlineDoneAt`. A document without a deadline reports `.noDeadline`.
        case deadlineDone(Bool)
    }

    /// What an edit did.
    public enum Outcome: Sendable, Equatable {
        /// The field changed and was saved.
        case saved
        /// The document already had that value: nothing was written.
        case unchanged
        /// No document with that `instanceID` (deleted meanwhile).
        case noDocument
        /// The document is in the trash: trashed documents are not edited.
        case trashed
        /// The correspondent, type or tag is not a live record (gone or merged meanwhile).
        case noMetadata
        /// A done toggle on a document that has no deadline (removed meanwhile, on this device or by sync).
        case noDeadline
    }

    public enum MetadataError: Error, Equatable {
        /// The name is empty after trimming.
        case emptyName
    }

    public let context: ModelContext
    private let now: () -> Date
    private let saveContext: (ModelContext) throws -> Void

    /// - Parameters:
    ///   - context: the main context, so the library's read sees the edit at once.
    ///   - now: the clock for `modifiedAt` and a new record's `createdAt`.
    ///   - save: saves the context; tests pass one that fails.
    public init(
        context: ModelContext, now: @escaping () -> Date = { Date() },
        save: @escaping (ModelContext) throws -> Void = { try $0.save() }
    ) {
        self.context = context
        self.now = now
        saveContext = save
    }

    /// Applies `change` to the document with `instanceID`.
    @discardableResult
    public func apply(_ change: Change, to instanceID: UUID) throws -> Outcome {
        guard let document = try fetchDocument(instanceID) else { return .noDocument }
        guard document.deletedAt == nil else { return .trashed }
        switch change {
        case .title(let title):
            let title = normalizedTitle(title)
            guard document.title != title else { return .unchanged }
            document.title = title
        case .documentDate(let date):
            guard document.documentDate != date else { return .unchanged }
            document.documentDate = date
        case .inbox(let isInbox):
            guard document.isInbox != isInbox else { return .unchanged }
            document.isInbox = isInbox
        case .correspondent(let target):
            guard document.correspondent?.instanceID != target else { return .unchanged }
            if let target {
                guard let record = try fetchLive(Correspondent.self, target) else { return .noMetadata }
                document.correspondent = record
            } else {
                document.correspondent = nil
            }
        case .documentType(let target):
            guard document.documentType?.instanceID != target else { return .unchanged }
            if let target {
                guard let record = try fetchLive(DocumentType.self, target) else { return .noMetadata }
                document.documentType = record
            } else {
                document.documentType = nil
            }
        case .tag(let target, true):
            let tags = document.tags ?? []
            guard !tags.contains(where: { $0.instanceID == target }) else { return .unchanged }
            guard let record = try fetchLive(Tag.self, target) else { return .noMetadata }
            document.tags = tags + [record]
        case .tag(let target, false):
            let tags = document.tags ?? []
            let removed = try tagsShownAs(target, among: tags)
            guard !removed.isEmpty else { return .unchanged }
            document.tags = tags.filter { !removed.contains($0.instanceID) }
        case .deadline(let day, let label):
            let label = label.trimmingCharacters(in: .whitespacesAndNewlines)
            if document.deadline?.day == day {
                guard document.deadlineLabel != label else { return .unchanged }
                document.deadlineLabel = label
            } else {
                document.deadlineDay = day.storedValue
                if document.deadlineLabel != label { document.deadlineLabel = label }
                document.deadlineSetAt = now()
                if document.deadlineDoneAt != nil { document.deadlineDoneAt = nil }
            }
        case .clearDeadline(let dismissed):
            let raisesDismissal = dismissed.map { Self.raises(document.deadlineDismissedDay, to: $0) } ?? false
            guard
                !document.deadlineDay.isEmpty || !document.deadlineLabel.isEmpty || document.deadlineSetAt != nil
                    || document.deadlineDoneAt != nil || raisesDismissal
            else { return .unchanged }
            if !document.deadlineDay.isEmpty { document.deadlineDay = "" }
            if !document.deadlineLabel.isEmpty { document.deadlineLabel = "" }
            if document.deadlineSetAt != nil { document.deadlineSetAt = nil }
            if document.deadlineDoneAt != nil { document.deadlineDoneAt = nil }
            if let dismissed, raisesDismissal { document.deadlineDismissedDay = dismissed.storedValue }
        case .deadlineDone(let isDone):
            guard document.deadline != nil else { return .noDeadline }
            guard (document.deadlineDoneAt != nil) != isDone else { return .unchanged }
            document.deadlineDoneAt = isDone ? now() : nil
        }
        document.touch(now())
        try save()
        return .saved
    }

    /// The live record of `kind` named `name`: an existing one with the same merge key, or a new one, saved.
    /// New tags are top level. Returns its `instanceID`.
    public func createMetadata(kind: MetadataKind, name: String) throws -> UUID {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = MetadataName.normalized(name)
        guard !key.isEmpty else { throw MetadataError.emptyName }
        switch kind {
        case .correspondent:
            let existing = try context.fetch(FetchDescriptor<Correspondent>()).filter {
                $0.isLive && MetadataName.normalized($0.name) == key
            }
            if let keeper = Self.keeper(existing, \.createdAt, \.instanceID) { return keeper.instanceID }
            return try insert(Correspondent(name: name, createdAt: now()))
        case .documentType:
            let existing = try context.fetch(FetchDescriptor<DocumentType>()).filter {
                $0.isLive && MetadataName.normalized($0.name) == key
            }
            if let keeper = Self.keeper(existing, \.createdAt, \.instanceID) { return keeper.instanceID }
            return try insert(DocumentType(name: name, createdAt: now()))
        case .tag:
            let existing = try context.fetch(FetchDescriptor<Tag>()).filter {
                $0.isLive && $0.parent == nil && MetadataName.normalized($0.name) == key
            }
            if let keeper = Self.keeper(existing, \.createdAt, \.instanceID) { return keeper.instanceID }
            return try insert(Tag(name: name, createdAt: now()))
        }
    }

    // MARK: Reading

    private func fetchDocument(_ instanceID: UUID) throws -> Document? {
        try first(FetchDescriptor<Document>(predicate: #Predicate { $0.instanceID == instanceID }))
    }

    private func fetchLive(_: Correspondent.Type, _ instanceID: UUID) throws -> Correspondent? {
        try first(FetchDescriptor(predicate: #Predicate { $0.instanceID == instanceID && $0.mergedIntoID == nil }))
    }

    private func fetchLive(_: DocumentType.Type, _ instanceID: UUID) throws -> DocumentType? {
        try first(FetchDescriptor(predicate: #Predicate { $0.instanceID == instanceID && $0.mergedIntoID == nil }))
    }

    private func fetchLive(_: Tag.Type, _ instanceID: UUID) throws -> Tag? {
        try first(FetchDescriptor(predicate: #Predicate { $0.instanceID == instanceID && $0.mergedIntoID == nil }))
    }

    private func first<T: PersistentModel>(_ descriptor: FetchDescriptor<T>) throws -> T? {
        var descriptor = descriptor
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    /// The `instanceID`s among `tags` that the library shows as the live tag `target`: the tag itself, and
    /// tombstones whose `mergedIntoID` chain ends at it (`LibraryMapping`). The chains are read only when the
    /// document refers to a tombstone.
    private func tagsShownAs(_ target: UUID, among tags: [Tag]) throws -> Set<UUID> {
        var shown = Set(tags.map(\.instanceID).filter { $0 == target })
        let tombstones = tags.filter { !$0.isLive }
        guard !tombstones.isEmpty else { return shown }
        let metadata = try StoreLibrarySource.metadata(in: context).filter { $0.kind == .tag }
        let chains = MetadataChains(RepairSnapshot(metadata: metadata))
        for tombstone in tombstones {
            if case .live(let end)? = chains.end(of: tombstone.instanceID), end == target {
                shown.insert(tombstone.instanceID)
            }
        }
        return shown
    }

    // MARK: Writing

    private func insert(_ record: some PersistentModel & MetadataRecord) throws -> UUID {
        context.insert(record)
        try save()
        return record.instanceID
    }

    /// Saves, or discards every unsaved change of the context and rethrows: nothing of a failed edit stays
    /// pending for a later save. The editor's own changes are the only ones the main context holds unsaved.
    private func save() throws {
        do {
            try saveContext(context)
        } catch {
            context.rollback()
            throw error
        }
    }

    /// Whether writing `day` as the dismissed day raises it: the `max(stored, new)` rule (re-review N3 of #12's plan).
    /// A stored value that does not read as a day (the read rule) counts as none, so any day raises it.
    static func raises(_ stored: String, to day: DeadlineDay) -> Bool {
        guard let current = DeadlineDay(storedValue: stored) else { return true }
        return day > current
    }

    /// The first record in `keeperOrder`: oldest `createdAt`, then the smallest `instanceID.uuidString`.
    private static func keeper<T>(_ records: [T], _ createdAt: KeyPath<T, Date>, _ instanceID: KeyPath<T, UUID>)
        -> T?
    {
        records.min { lhs, rhs in
            lhs[keyPath: createdAt] != rhs[keyPath: createdAt]
                ? lhs[keyPath: createdAt] < rhs[keyPath: createdAt]
                : lhs[keyPath: instanceID].uuidString < rhs[keyPath: instanceID].uuidString
        }
    }
}

/// A tag, correspondent or type: what `createMetadata` returns of it.
protocol MetadataRecord {
    var instanceID: UUID { get }
}

extension Correspondent: MetadataRecord {}
extension DocumentType: MetadataRecord {}
extension Tag: MetadataRecord {}
