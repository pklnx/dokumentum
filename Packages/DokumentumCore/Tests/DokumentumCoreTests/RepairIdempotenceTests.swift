import DokumentumCore
import DokumentumKit
import DokumentumTestSupport
import Foundation
import SwiftData
import Testing

/// I7: a second run on repaired data plans nothing and does not save, so the repair's own save, which the
/// store change observer reports, does not start an endless series of runs.
struct RepairIdempotenceTests {
    @Test func aSecondRunChangesNothingAndDoesNotSave() async throws {
        let store = try TemporaryStore()
        defer { store.remove() }
        try store.seed(
            RepairSnapshot(
                documents: [document(1, correspondent: 10, tags: [20, 21]), document(2, correspondent: 31)],
                metadata: [
                    correspondent(10, "Old", mergedInto: 11), correspondent(11, "New"),
                    tag(20, "Tax"), tag(21, "tax"), tag(22, "A", parent: 23), tag(23, "B", parent: 22),
                    correspondent(30, "Loop", mergedInto: 31), correspondent(31, "Loop", mergedInto: 30),
                ],
                blobs: [blob(.file, 40, documentID: 2), blob(.thumbnail, 41, documentID: 9)]))
        // `didSave` is posted synchronously inside `save()`, so the count is final when a run returns.
        let saves = TestSignal()
        let observed = ObjectIdentifier(store.container)
        let token = NotificationCenter.default.addObserver(forName: ModelContext.didSave, object: nil, queue: nil) {
            notification in
            if let context = notification.object as? ModelContext, ObjectIdentifier(context.container) == observed {
                saves.fire()
            }
        }
        defer { NotificationCenter.default.removeObserver(token) }

        let first = try await CheckedRepair.run(store)
        #expect(first.report.saves > 0)
        #expect(saves.count == first.report.saves, "one save per pass that changed something")
        // The revive needs a second run to settle (the re-point to the revived record comes next).
        let second = try await CheckedRepair.run(store)
        let savesBefore = saves.count
        let third = try await CheckedRepair.run(store)
        #expect(!second.plan.isEmpty)
        #expect(third.plan.isEmpty)
        #expect(third.report.saves == 0)
        #expect(saves.count == savesBefore, "the third run posted no didSave")
        #expect(third.after.sorted == third.before.sorted)
    }
}
