import DokumentumKit
import Foundation
import SwiftData

/// Reads the deadlines the reminders need (#12, part 3; plan §9): every `Document` row with a deadline day, in a context
/// of its own off the main actor, and never a text, file or thumbnail table (`ReminderSQLTests`). A day that
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
        let descriptor = FetchDescriptor<Document>(predicate: #Predicate { $0.deadlineDay != "" })
        return try context.fetch(descriptor).compactMap { document in
            guard let deadline = document.deadline else { return nil }
            return ReminderDeadline(
                instanceID: document.instanceID, deadline: deadline, title: document.title,
                isTrashed: document.deletedAt != nil)
        }
    }
}
