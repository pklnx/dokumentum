import DokumentumCoreTestSupport
import DokumentumKit
import DokumentumTestSupport
import Foundation
import SwiftData
import Testing

@testable import DokumentumCore

/// The documents the background tasks wait for (plan of #6, part 5): `pending` and `processing`, not trashed,
/// each `instanceID` once.
@MainActor
struct OpenDocumentsTests {
    @discardableResult
    private func insert(
        _ state: ProcessingState, trashed: Bool = false, instanceID: UUID? = nil, in context: ModelContext
    ) -> Document {
        let document = Document(title: "")
        if let instanceID { document.instanceID = instanceID }
        document.processingState = state
        if trashed { document.deletedAt = Date() }
        context.insert(document)
        return document
    }

    @Test func itCountsPendingAndProcessingDocumentsThatAreNotTrashed() throws {
        let container = try TestSupport.makeContainer()
        let context = ModelContext(container)
        let pending = insert(.pending, in: context)
        let processing = insert(.processing, in: context)
        let done = insert(.done, in: context)
        let failed = insert(.failed, in: context)
        let trashed = insert(.pending, trashed: true, in: context)
        // A copy that shares the pending document's `instanceID` counts once.
        insert(.pending, instanceID: pending.instanceID, in: context)
        try context.save()

        #expect(try OpenDocuments.count(in: container) == 2)
        let all: Set = [
            pending.instanceID, processing.instanceID, done.instanceID, failed.instanceID, trashed.instanceID,
        ]
        #expect(try OpenDocuments.count(in: container, among: all) == 2)
        #expect(try OpenDocuments.count(in: container, among: [done.instanceID, UUID()]) == 0, "a gone one is open")
        #expect(try OpenDocuments.count(in: container, among: [processing.instanceID]) == 1)
        #expect(try OpenDocuments.count(in: container, among: []) == 0)
    }

    /// It reads what another context saved, as the queue's result writes.
    @Test func itSeesAnotherContextsSave() throws {
        let container = try TestSupport.makeContainer()
        let context = ModelContext(container)
        let document = insert(.pending, in: context)
        try context.save()
        #expect(try OpenDocuments.count(in: container, among: [document.instanceID]) == 1)

        document.processingState = .done
        try context.save()
        #expect(try OpenDocuments.count(in: container, among: [document.instanceID]) == 0)
    }
}
