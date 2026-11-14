import DokumentumKit
import Foundation
import SwiftData

/// Reads the deadlines the reminders need (#12, part 3; plan §9): every `Document` row with a deadline day, in a context
/// of its own off the main actor, and never a text, file or thumbnail table (`ReminderSQLTests`). Of copies sharing an
/// `instanceID` only the oldest (`RowRecords.oldestFirst`) counts, chosen among all copies before any filter. A day that
/// does not read as one (the read rule) is no deadline. A failed fetch throws, and the reconcile then changes nothing
/// (R2): a failed read is never "no deadlines".
public struct ReminderStoreReader: Sendable {
    public let container: ModelContainer

    public init(container: ModelContainer) {
        self.container = container
    }

    @concurrent
    public func read() async throws -> [ReminderDeadline] {
        try Self.read(in: container)
    }

    /// The same, synchronously, in a new context of `container` (the SQL test records one thread).
    public static func read(in container: ModelContainer) throws -> [ReminderDeadline] {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        // Copies sharing an `instanceID` (until step 16's dedupe): the oldest `createdAt` stands for them, as in every
        // other reader (`RowRecords.oldestFirst`), chosen among **all** copies before anything else is looked at (review
        // A N5 / B N7 of #222): an oldest copy without a deadline means no reminder, whatever a newer copy says. Two
        // reads of the `Document` table: the documents that have a deadline day on any copy, then every copy of those.
        let withDay = try context.fetch(FetchDescriptor<Document>(predicate: #Predicate { $0.deadlineDay != "" }))
        let instanceIDs = Array(Set(withDay.map(\.instanceID)))
        guard !instanceIDs.isEmpty else { return [] }
        let copies = try context.fetch(
            FetchDescriptor<Document>(predicate: #Predicate { instanceIDs.contains($0.instanceID) }))
        var seen = Set<UUID>()
        return RowRecords.oldestFirst(copies).compactMap { document in
            guard seen.insert(document.instanceID).inserted, let deadline = document.deadline else { return nil }
            return ReminderDeadline(
                instanceID: document.instanceID, deadline: deadline, title: document.title,
                isTrashed: document.deletedAt != nil)
        }
    }
}
