import DokumentumKit
import Foundation
import SwiftData

/// The documents processing has not finished yet, for the app's background tasks (plan of #6, part 5): whether the
/// app asks for a processing task when it goes to the background, and how far a continued-processing task got.
public enum OpenDocuments {
    /// How many documents are `pending`, `processing` or `classify` (waiting for the classification step, #8 review N2)
    /// and not trashed (a trashed one waits for its restore, so it
    /// is no work for a background task), counted by `instanceID`: copies that share one count once. With
    /// `instanceIDs`, only those documents count; one that is gone counts as finished.
    ///
    /// Reads `Document` rows only, in a fresh context, so it sees what the queue saved.
    public static func count(in container: ModelContainer, among instanceIDs: Set<UUID>? = nil) throws -> Int {
        let pending = ProcessingState.pending.storedValue ?? "pending"
        let processing = ProcessingState.processing.storedValue ?? "processing"
        let classify = ProcessingState.classify.storedValue ?? "classify"
        let context = ModelContext(container)
        var descriptor: FetchDescriptor<Document>
        if let instanceIDs {
            guard !instanceIDs.isEmpty else { return 0 }
            let ids = Array(instanceIDs)
            descriptor = FetchDescriptor(
                predicate: #Predicate {
                    ids.contains($0.instanceID)
                        && ($0.processingStateRaw == pending || $0.processingStateRaw == processing
                            || $0.processingStateRaw == classify)
                        && $0.deletedAt == nil
                })
        } else {
            descriptor = FetchDescriptor(
                predicate: #Predicate {
                    ($0.processingStateRaw == pending || $0.processingStateRaw == processing
                        || $0.processingStateRaw == classify) && $0.deletedAt == nil
                })
        }
        descriptor.propertiesToFetch = [\.instanceID]
        return Set(try context.fetch(descriptor).map(\.instanceID)).count
    }
}
