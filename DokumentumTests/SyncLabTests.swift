import DokumentumCore
import DokumentumKit
import DokumentumTestSupport
import Foundation
import Observation
import SwiftData
import Testing

@testable import Dokumentum

/// The Sync lab itself (`SyncLab`, plan of #31, Approach 3; reviews A and B of PR #155): the first write of a launch on
/// a store on disk waits for the question, the lab's "Empty lab trash" deletes lab documents only, and the device
/// settings (re-queue flag, classification switch) change only with a store on disk. In-memory stores stand in for
/// the store; the `LaunchStore` decides whether the lab asks.
@MainActor
struct SyncLabTests {
    /// A defaults suite of the test's own, so the app's settings are never touched.
    private let suite = "DokumentumTests-SyncLab-\(UUID().uuidString)"

    private func makeLab(onDisk: Bool) throws -> (lab: SyncLab, container: ModelContainer, writes: TestSignal) {
        let container = try makeInMemoryContainer()
        let launchStore =
            onDisk
            ? LaunchStore(choice: .local, opened: .local)
            : LaunchStore(choice: .inMemory(seed: false), opened: .inMemory)
        let lab = SyncLab(
            container: container, launchStore: launchStore, deviceID: "LAB-DEVICE",
            importer: DocumentImporter(container: container, deviceID: "LAB-DEVICE"), processing: nil, repair: nil,
            search: SearchIndexer(container: container), monitor: nil, takeoverInterval: nil, defaultsSuite: suite)
        let writes = TestSignal()
        lab.didFinishWrite = { writes.fire() }
        return (lab, container, writes)
    }

    private func titles(in container: ModelContainer) throws -> Set<String> {
        Set(try ModelContext(container).fetch(FetchDescriptor<Document>()).map(\.title))
    }

    /// Inserts a document that is not the lab's (no `SyncLab-` prefix), in the trash.
    private func insertForeignTrashedDocument(in container: ModelContainer) throws {
        let context = ModelContext(container)
        let document = Document(title: "Rechnung der Stadtwerke", createdAt: Date())
        document.originalFileName = "Rechnung.pdf"
        document.deletedAt = Date()
        context.insert(document)
        try context.save()
    }

    /// On a store on disk the first write waits for the question and nothing is written before it; "Empty lab trash"
    /// then deletes the trashed lab document and keeps the trashed document the lab did not create (review A, B1);
    /// the next write of the launch runs without a question.
    @Test func emptyLabTrashAsksFirstAndKeepsOtherDocuments() async throws {
        let (lab, container, writes) = try makeLab(onDisk: true)
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let trashedLab = try SyncLabActions.insertLegacyDocument(
            in: container, deviceID: "LAB-DEVICE", word: "syncwaaaaaa", pages: 1)
        let keptLab = try SyncLabActions.insertLegacyDocument(
            in: container, deviceID: "LAB-DEVICE", word: "syncwbbbbbb", pages: 1)
        _ = try DocumentTrash(context: ModelContext(container)).moveToTrash([trashedLab])
        try insertForeignTrashedDocument(in: container)
        await lab.refresh()
        #expect(SyncLab.labTrash(of: lab.rows ?? []) == [trashedLab])

        lab.emptyTrash()
        #expect(lab.isConfirmingWrite, "the first write on a store on disk did not ask")
        #expect(try titles(in: container).count == 3, "something was written before the question was answered")

        lab.confirmWrites()
        await writes.wait(for: 1, "the confirmed write did not finish")
        #expect(
            try titles(in: container) == ["SyncLab legacy syncwbbbbbb", "Rechnung der Stadtwerke"],
            "Empty lab trash deleted more than the trashed lab document")
        #expect(lab.message?.contains("other trashed documents kept: 1") == true)

        lab.trash(keptLab)
        #expect(!lab.isConfirmingWrite, "a second write of the launch asked again")
        await writes.wait(for: 2, "the second write did not run")
        #expect(lab.rows?.first { $0.instanceID == keptLab }?.isTrashed == true)
    }

    /// A cancelled question writes nothing, and the next write asks again.
    @Test func aCancelledQuestionWritesNothingAndAsksAgain() async throws {
        let (lab, container, writes) = try makeLab(onDisk: true)
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let id = try SyncLabActions.insertLegacyDocument(
            in: container, deviceID: "LAB-DEVICE", word: "syncwcccccc", pages: 1)

        lab.deleteDirectly(id)
        #expect(lab.isConfirmingWrite)
        lab.cancelWrite()
        #expect(!lab.isConfirmingWrite)
        #expect(try titles(in: container) == ["SyncLab legacy syncwcccccc"])
        #expect(writes.count == 0)

        lab.deleteDirectly(id)
        #expect(lab.isConfirmingWrite, "the write after a cancel did not ask")
        lab.confirmWrites()
        await writes.wait(for: 1, "the confirmed delete did not run")
        #expect(try titles(in: container).isEmpty)
    }

    /// With an in-memory store the lab writes documents without a question, but it never changes the device's
    /// settings: those are the app's own defaults on this Mac or simulator (review B, N7).
    @Test func anInMemoryStoreNeverChangesTheDeviceSettings() async throws {
        let (lab, container, writes) = try makeLab(onDisk: false)
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: ProcessingRequeue.flagKey)
        #expect(!lab.canChangeDeviceSettings)

        lab.resetRequeueFlag()
        lab.setClassification(false)
        #expect(!lab.isConfirmingWrite)
        #expect(lab.isRequeueDone, "the re-queue flag was reset on an in-memory store")
        #expect(lab.isClassificationEnabled, "the classification switch changed on an in-memory store")

        let id = try SyncLabActions.insertLegacyDocument(
            in: container, deviceID: "LAB-DEVICE", word: "syncwdddddd", pages: 1)
        lab.deleteDirectly(id)
        #expect(!lab.isConfirmingWrite, "an in-memory store asked")
        await writes.wait(for: 1, "the write did not run")
        #expect(try titles(in: container).isEmpty)
    }

    /// With a store on disk the device settings change after the question: the re-queue flag is cleared and the
    /// classification switch follows the toggle (#8's `classification.enabled`).
    @Test func aStoreOnDiskChangesTheDeviceSettingsAfterTheQuestion() async throws {
        let (lab, _, writes) = try makeLab(onDisk: true)
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: ProcessingRequeue.flagKey)
        #expect(lab.canChangeDeviceSettings)
        #expect(lab.isClassificationEnabled, "the switch is on unless set")

        // The toggle reads `isClassificationEnabled`: a confirmed write must change it observably (review B, N3).
        let changed = TestSignal()
        withObservationTracking {
            _ = lab.isClassificationEnabled
        } onChange: {
            changed.fire()
        }
        lab.setClassification(false)
        #expect(lab.isConfirmingWrite)
        #expect(lab.isClassificationEnabled, "the switch changed before the question was answered")
        #expect(changed.count == 0)
        lab.confirmWrites()
        await writes.wait(for: 1, "the switch was not set")
        #expect(!lab.isClassificationEnabled)
        #expect(changed.count == 1, "the toggle's value changed without notifying its view")
        #expect(defaults.object(forKey: ClassificationSettings.enabledKey) as? Bool == false)

        lab.resetRequeueFlag()
        await writes.wait(for: 2, "the flag was not reset")
        #expect(!lab.isRequeueDone)
    }

    /// A change of the classification switch outside the lab (later #8 part 3's settings switch) shows at the "This
    /// device" section's next periodic read and when the lab refreshes, so step Z's check never reads a stale value
    /// (review B of round 2, N1).
    @Test func theClassificationLineFollowsAChangeOutsideTheLab() async throws {
        let (lab, _, _) = try makeLab(onDisk: true)
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(lab.isClassificationEnabled)

        ClassificationSettings(defaultsSuite: suite).isEnabled = false
        _ = await lab.refreshThisDevice()
        #expect(!lab.isClassificationEnabled, "the periodic read kept the old value")

        ClassificationSettings(defaultsSuite: suite).isEnabled = true
        await lab.refresh()
        #expect(lab.isClassificationEnabled, "the lab's refresh kept the old value")
    }
}
