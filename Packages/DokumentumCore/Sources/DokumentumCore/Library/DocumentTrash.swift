import Foundation
import SwiftData

/// The trash (plan of #3, part 4): moves documents into it, restores them, and empties it. **The only code
/// outside DEBUG tools that deletes a `Document`.**
///
/// - **Move and restore** set or clear `deletedAt` and call `touch()`; every other field stays as it was, the
///   inbox flag included, so a restored document comes back where it was. One save per call, none if nothing
///   changed. They work in the main context, so the library's read sees them at once.
/// - **Empty Trash** takes the set of `instanceID`s the confirmation showed. Right before deleting, it reads
///   them again from the store, in a context of its own, and deletes only those that are still in the trash: a
///   document restored meanwhile (on this device, or on another one and imported since) stays, and so does one
///   trashed after the confirmation was shown. One save.
/// - **What goes with a document:** its linked `DocumentFile`, `DocumentThumbnail` and `DocumentText`, by the
///   model's cascade. Tags, correspondents and types stay. A file, thumbnail or text that is not linked to its
///   document at that moment (still arriving by sync) is not deleted: it stays as an orphan the repair counts,
///   until #32 (plan of #3, T7).
@MainActor
public struct DocumentTrash {
    public let context: ModelContext
    private let now: () -> Date

    /// - Parameters:
    ///   - context: the main context, so the library's read sees a move or a restore at once.
    ///   - now: the clock for `deletedAt` and `modifiedAt`.
    public init(context: ModelContext, now: @escaping () -> Date = { Date() }) {
        self.context = context
        self.now = now
    }

    /// Moves the documents with these `instanceID`s into the trash. Returns those it moved: a document that is
    /// gone or already in the trash is left alone.
    @discardableResult
    public func moveToTrash(_ instanceIDs: Set<UUID>) throws -> Set<UUID> {
        let documents = try Self.fetch(instanceIDs, in: context).filter { $0.deletedAt == nil }
        guard !documents.isEmpty else { return [] }
        let now = now()
        for document in documents {
            document.deletedAt = now
            document.touch(now)
        }
        try context.save()
        return Set(documents.map(\.instanceID))
    }

    /// Takes the documents with these `instanceID`s out of the trash. Returns those it restored: a document that
    /// is gone or not in the trash is left alone.
    @discardableResult
    public func restore(_ instanceIDs: Set<UUID>) throws -> Set<UUID> {
        let documents = try Self.fetch(instanceIDs, in: context).filter { $0.deletedAt != nil }
        guard !documents.isEmpty else { return [] }
        let now = now()
        for document in documents {
            document.deletedAt = nil
            document.touch(now)
        }
        try context.save()
        return Set(documents.map(\.instanceID))
    }

    /// Deletes for good the documents of `confirmed` that are still in the trash, with their linked file,
    /// thumbnail and text. Returns the `instanceID`s it deleted.
    ///
    /// The documents are read again in a new context, so the check sees the store as it is now and does not rely
    /// on the main context having merged another context's save. (Measured on this part: the main context's
    /// fetch did see another context's saved restore in tests; the own context keeps the check independent of
    /// that, e.g. of when a CloudKit import is merged.)
    @discardableResult
    public func emptyTrash(confirmed: Set<UUID>) throws -> Set<UUID> {
        guard !confirmed.isEmpty else { return [] }
        let fresh = ModelContext(context.container)
        fresh.autosaveEnabled = false
        let documents = try Self.fetch(confirmed, in: fresh).filter { $0.deletedAt != nil }
        guard !documents.isEmpty else { return [] }
        let deleted = Set(documents.map(\.instanceID))
        for document in documents {
            fresh.delete(document)
        }
        try fresh.save()
        return deleted
    }

    /// The documents with these `instanceID`s, trashed or not.
    private static func fetch(_ instanceIDs: Set<UUID>, in context: ModelContext) throws -> [Document] {
        guard !instanceIDs.isEmpty else { return [] }
        let ids = Array(instanceIDs)
        return try context.fetch(FetchDescriptor<Document>(predicate: #Predicate { ids.contains($0.instanceID) }))
    }
}
