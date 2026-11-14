import DokumentumCoreTestSupport
import DokumentumKit
import DokumentumTestSupport
import Foundation
import SwiftData
import Testing

@testable import DokumentumCore

/// The indexer keeps the in-memory index in step with the store (#13, part 1; plan §3, D1–D3): one test per event of
/// the plan's table, the copies, launches, failures, the setting and an unavailable index. Every test uses
/// `InMemorySpotlightIndex`; nothing here reaches the system's index.
struct SpotlightIndexerTests {
    static let thumbnail = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10])

    /// An import after the launch pass reaches the index through the save, with every attribute of the plan's §1.
    @Test func anImportGivesOneItemWithEveryAttribute() async throws {
        let harness = try SpotlightHarness()
        let passes = PassSignal()
        let indexer = harness.indexer(hooks: passes.hooks)
        defer { indexer.stop() }
        indexer.start()
        await passes.ended.wait()

        let date = Calendar.current.date(from: DateComponents(year: 2026, month: 3, day: 9, hour: 12))!
        let id = try SpotlightStore.insert(
            .init(
                title: "Stromrechnung", text: "Zählerstand 4711", correspondent: "Stadtwerke", documentType: "Rechnung",
                tags: ["Wohnung"], thumbnail: Self.thumbnail, documentDate: date), in: harness.container)
        await passes.ended.wait(for: 2)

        let items = await harness.items()
        #expect(items.count == 1)
        let item = try #require(items[id])
        #expect(item.title == "Stromrechnung")
        #expect(item.domainIdentifier == "documents")
        #expect(item.expirationDate == .distantFuture)
        #expect(item.contentType == "com.adobe.pdf")
        #expect(item.contentDescription == "Stadtwerke · Rechnung · Mar 9, 2026")
        #expect(item.keywords == ["Stadtwerke", "Rechnung", "Wohnung"])
        #expect(item.textContent == "Zählerstand 4711")
        #expect(item.thumbnailData == Self.thumbnail)
        #expect(item.contentCreationDate == date)
        #expect(harness.fingerprinted() == [id])
    }

    /// A text of 300,000 bytes: the item holds its head of at most 200,000 bytes, cut at a line break (N3).
    @Test func aLongTextIsCutTo200000Bytes() async throws {
        let harness = try SpotlightHarness()
        let line = String(repeating: "Wort ", count: 19) + "Ende\n"
        let id = try SpotlightStore.insert(
            .init(title: "Lang", text: String(repeating: line, count: 3_000)), in: harness.container)
        await harness.indexer().runPass()
        let text = try #require(await harness.items()[id]).textContent
        #expect(text.utf8.count <= SpotlightLimits.textBytes)
        #expect(text.utf8.count > SpotlightLimits.textBytes - 100)
        #expect(text.hasSuffix("Ende"))
    }

    enum Edit: String, CaseIterable, Sendable {
        case title, documentDate, correspondent, documentType, tag, inbox
    }

    /// Each edit the editor makes reaches that item only.
    @Test(arguments: Edit.allCases)
    func anEditPushesThatItemOnly(edit: Edit) async throws {
        let harness = try SpotlightHarness()
        let ids = try SpotlightStore.insert(
            (0..<3).map { .init(title: "Akte \($0)", correspondent: "Amt", documentType: "Brief", tags: ["Steuer"]) },
            in: harness.container)
        let indexer = harness.indexer()
        await indexer.runPass()
        await harness.index.clearCalls()

        try SpotlightStore.edit(ids[1], in: harness.container) { document, context in
            switch edit {
            case .title: document.title = "Neuer Titel"
            case .documentDate: document.documentDate = Date(timeIntervalSinceReferenceDate: 810_000_000)
            case .correspondent:
                let record = Correspondent(name: "Finanzamt")
                context.insert(record)
                document.correspondent = record
            case .documentType:
                let record = DocumentType(name: "Bescheid")
                context.insert(record)
                document.documentType = record
            case .tag:
                let tag = DokumentumCore.Tag(name: "Haus")
                context.insert(tag)
                document.tags = (document.tags ?? []) + [tag]
            case .inbox: document.isInbox = false
            }
        }
        let report = await indexer.runPass()
        #expect(report.outcome == .done)
        #expect(report.full == nil)
        #expect(await harness.pushed() == [ids[1]])
        #expect(await harness.deleted().isEmpty)
        let item = try #require(await harness.items()[ids[1]])
        switch edit {
        case .title: #expect(item.title == "Neuer Titel")
        case .documentDate: #expect(item.contentCreationDate == Date(timeIntervalSinceReferenceDate: 810_000_000))
        case .correspondent: #expect(item.keywords.contains("Finanzamt"))
        case .documentType: #expect(item.keywords.contains("Bescheid"))
        case .tag: #expect(item.keywords.contains("Haus"))
        case .inbox: break
        }
    }

    /// A tag rename changes the display paths of exactly the documents it tags.
    @Test func aTagRenamePushesExactlyTheTaggedDocuments() async throws {
        let harness = try SpotlightHarness()
        let ids = try SpotlightStore.insert(
            [.init(title: "A", tags: ["Steuer"]), .init(title: "B"), .init(title: "C", tags: ["Steuer"])],
            in: harness.container)
        let indexer = harness.indexer()
        await indexer.runPass()
        await harness.index.clearCalls()

        let context = ModelContext(harness.container)
        let tag = try #require(try context.fetch(FetchDescriptor<DokumentumCore.Tag>()).first)
        tag.name = "Steuern"
        try context.save()
        await indexer.runPass()
        #expect(Set(await harness.pushed()) == [ids[0], ids[2]])
        #expect(await harness.pushed().count == 2)
        #expect(try #require(await harness.items()[ids[0]]).keywords == ["Steuern"])
    }

    /// The processing queue writes the text in place, without `modifiedAt`: only the history names it.
    @Test func theProcessingQueuesTextWritePushesTheText() async throws {
        let harness = try SpotlightHarness()
        let ids = try SpotlightStore.insert(count: 3, in: harness.container)
        let indexer = harness.indexer()
        await indexer.runPass()
        await harness.index.clearCalls()

        try SpotlightStore.setText("Wasserzähler abgelesen", of: ids[2], in: harness.container)
        await indexer.runPass()
        #expect(await harness.pushed() == [ids[2]])
        #expect(try #require(await harness.items()[ids[2]]).textContent == "Wasserzähler abgelesen")
    }

    /// A thumbnail made later (or arriving by sync) and linked to its document reaches the item.
    @Test func aThumbnailLinkedLaterPushesTheThumbnail() async throws {
        let harness = try SpotlightHarness()
        let id = try SpotlightStore.insert(.init(title: "Scan"), in: harness.container)
        let indexer = harness.indexer()
        await indexer.runPass()
        #expect(try #require(await harness.items()[id]).thumbnailData == nil)
        await harness.index.clearCalls()

        try SpotlightStore.edit(id, in: harness.container) { document, context in
            let thumbnail = DocumentThumbnail(documentID: document.id, imageData: Self.thumbnail)
            context.insert(thumbnail)
            document.thumbnail = thumbnail
        }
        await indexer.runPass()
        #expect(await harness.pushed() == [id])
        #expect(try #require(await harness.items()[id]).thumbnailData == Self.thumbnail)
    }

    /// Trash removes the item, a restore adds it again, and Empty Trash leaves nothing (the item already went).
    @Test func trashDeletesRestorePushesAndEmptyTrashLeavesNothing() async throws {
        let harness = try SpotlightHarness()
        let ids = try SpotlightStore.insert(count: 2, in: harness.container)
        let indexer = harness.indexer()
        await indexer.runPass()
        await harness.index.clearCalls()

        try SpotlightStore.trash(ids[0], in: harness.container)
        await indexer.runPass()
        #expect(await harness.deleted() == [ids[0]])
        #expect(Set(await harness.items().keys) == [ids[1]])
        #expect(harness.fingerprinted() == [ids[1]])

        try SpotlightStore.trash(ids[0], in: harness.container, restore: true)
        await indexer.runPass()
        #expect(Set(await harness.items().keys) == Set(ids))

        try SpotlightStore.trash(ids[0], in: harness.container)
        await indexer.runPass()
        await harness.index.clearCalls()
        try SpotlightStore.edit(ids[0], in: harness.container) { document, context in context.delete(document) }
        let report = await indexer.runPass()
        #expect(report.outcome == .done)
        #expect(await harness.index.calls.allSatisfy { $0 == .lastClientState }, "nothing left to do")
        #expect(Set(await harness.items().keys) == [ids[1]])
    }

    /// Two documents sharing an `instanceID` (#205, #213) give one item, with the older copy's title and text. When
    /// that copy and its text are deleted, the next event pushes the other copy's.
    @Test func copiesGiveOneItemFromTheOlderCopyUntilItGoes() async throws {
        let harness = try SpotlightHarness()
        let id = try SpotlightStore.insert(
            .init(title: "Alt", text: "alter Text", createdAt: Date(timeIntervalSinceReferenceDate: 800_000_000)),
            in: harness.container)
        try SpotlightStore.insert(
            .init(
                title: "Neu", text: "neuer Text", createdAt: Date(timeIntervalSinceReferenceDate: 800_000_100),
                instanceID: id), in: harness.container)
        let indexer = harness.indexer()
        await indexer.runPass()
        #expect(await harness.items().count == 1)
        #expect(try #require(await harness.items()[id]).title == "Alt")
        #expect(try #require(await harness.items()[id]).textContent == "alter Text")

        let context = ModelContext(harness.container)
        let older = try #require(try SpotlightStore.documents(id, in: context).first)
        #expect(older.title == "Alt")
        context.delete(older)
        try context.save()
        await indexer.runPass()
        #expect(await harness.items().count == 1)
        #expect(try #require(await harness.items()[id]).textContent == "neuer Text")
        #expect(try #require(await harness.items()[id]).title == "Neu")
    }

    /// The oldest copy is chosen **before** any filter (#222's review B, N7): when the oldest copy is in the trash, the
    /// document is not live, and a newer copy outside the trash does not show through; an oldest copy with an empty
    /// text keeps its empty text, not the newer copy's.
    @Test func theOldestCopyIsChosenBeforeTheTrashOrTextFilter() async throws {
        let harness = try SpotlightHarness()
        let trashed = try SpotlightStore.insert(
            .init(title: "Alt", text: "alter Text", createdAt: Date(timeIntervalSinceReferenceDate: 800_000_000)),
            in: harness.container)
        try SpotlightStore.trash(trashed, in: harness.container)
        try SpotlightStore.insert(
            .init(
                title: "Neu", text: "neuer Text", createdAt: Date(timeIntervalSinceReferenceDate: 800_000_100),
                instanceID: trashed), in: harness.container)
        let empty = try SpotlightStore.insert(
            .init(title: "Leer", text: "", createdAt: Date(timeIntervalSinceReferenceDate: 800_000_000)),
            in: harness.container)
        try SpotlightStore.insert(
            .init(
                title: "Voll", text: "Text der Kopie", createdAt: Date(timeIntervalSinceReferenceDate: 800_000_100),
                instanceID: empty), in: harness.container)

        await harness.indexer().runPass()
        let items = await harness.items()
        #expect(items[trashed] == nil, "the kept copy is trashed: not indexed")
        let item = try #require(items[empty])
        #expect(item.title == "Leer")
        #expect(item.textContent == "")
        #expect(items.count == 1)
    }

    /// The next launch on the same store, state file and index pushes nothing; one edit between the launches pushes
    /// one item.
    @Test func theNextLaunchPushesOnlyWhatChanged() async throws {
        let store = try TemporaryStore()
        defer { store.remove() }
        let file = SpotlightStateFile(url: store.folder.appending(path: "Spotlight/State.json"))
        let harness = try SpotlightHarness(container: store.container)
        let ids = try SpotlightStore.insert(count: 5, in: store.container)
        let first = await harness.indexer(stateStore: file).runPass()
        #expect(first.full == .noState)
        #expect(first.pushed == 5)

        await harness.index.clearCalls()
        let second = await harness.indexer(stateStore: file).runPass()
        #expect(second.full == nil)
        #expect(second.pushed == 0)
        #expect(await harness.index.calls == [.lastClientState])

        try SpotlightStore.setText("geändert", of: ids[3], in: store.container)
        let third = await harness.indexer(stateStore: file).runPass()
        #expect(third.full == nil)
        #expect(await harness.pushed() == [ids[3]])
        #expect(try #require(await harness.items()[ids[3]]).textContent == "geändert")
    }

    /// A failing `beginBatch`, `index` or `endBatch` leaves the state as it was (fingerprints, client state and
    /// history position), and the next event pushes the same items: an edit (a new fingerprint) and a text written by
    /// the processing queue (only the history names it).
    @Test(arguments: [InMemorySpotlightIndex.Operation.beginBatch, .index, .endBatch])
    func aFailingBatchLeavesTheStateAndIsPushedAgain(operation: InMemorySpotlightIndex.Operation) async throws {
        let failing = HookSwitch()
        let harness = try SpotlightHarness(index: InMemorySpotlightIndex(hook: failing.hook))
        let ids = try SpotlightStore.insert(count: 3, in: harness.container)
        let indexer = harness.indexer()
        await indexer.runPass()
        let before = try #require(harness.state.state)

        try SpotlightStore.edit(ids[0], in: harness.container) { document, _ in document.title = "Umbenannt" }
        try SpotlightStore.setText("später erkannt", of: ids[1], in: harness.container)
        failing.fail([operation])
        let failed = await indexer.runPass()
        #expect(failed.outcome == .failed)
        #expect(failing.failed == 1)
        #expect(harness.state.state == before)
        #expect(try #require(await harness.items()[ids[0]]).title == "Akte 0")
        #expect(try #require(await harness.items()[ids[1]]).textContent == "Inhalt 1")

        failing.clear()
        await harness.index.clearCalls()
        let again = await indexer.runPass()
        #expect(again.outcome == .done)
        #expect(again.full == nil)
        #expect(Set(await harness.pushed()) == [ids[0], ids[1]])
        #expect(await harness.index.batchViolations == 0)
        #expect(try #require(await harness.items()[ids[0]]).title == "Umbenannt")
        #expect(try #require(await harness.items()[ids[1]]).textContent == "später erkannt")
    }

    /// A failing delete keeps the fingerprint, so the next event deletes again.
    @Test func aFailingDeleteIsRetried() async throws {
        let failing = HookSwitch()
        let harness = try SpotlightHarness(index: InMemorySpotlightIndex(hook: failing.hook))
        let ids = try SpotlightStore.insert(count: 2, in: harness.container)
        let indexer = harness.indexer()
        await indexer.runPass()
        try SpotlightStore.trash(ids[0], in: harness.container)
        failing.fail([.delete])
        #expect(await indexer.runPass().outcome == .failed)
        #expect(harness.fingerprinted() == Set(ids))
        #expect(await harness.items()[ids[0]] != nil)

        failing.clear()
        await harness.index.clearCalls()
        #expect(await indexer.runPass().outcome == .done)
        #expect(await harness.deleted() == [ids[0]])
        #expect(Set(await harness.items().keys) == [ids[1]])
        #expect(harness.fingerprinted() == [ids[1]])
    }

    /// `endBatch` failing with a mismatch makes the next pass a full one.
    @Test func aMismatchMakesTheNextPassFull() async throws {
        let mismatch = Armed()
        let harness = try SpotlightHarness(
            index: InMemorySpotlightIndex(hook: { call in
                if call.operation == .endBatch, mismatch.isOn { throw SpotlightIndexError.mismatchedClientState }
            }))
        let ids = try SpotlightStore.insert(count: 2, in: harness.container)
        let indexer = harness.indexer()
        await indexer.runPass()
        try SpotlightStore.setText("neu", of: ids[0], in: harness.container)
        mismatch.turnOn()
        #expect(await indexer.runPass().outcome == .failed)

        let mismatchOff = HookSwitch()
        await harness.index.setHook(mismatchOff.hook)
        await harness.index.clearCalls()
        let next = await indexer.runPass()
        #expect(next.full == .requested)
        #expect(await harness.index.count(of: .deleteAll) == 1)
        #expect(Set(await harness.items().keys) == Set(ids))
        #expect(try #require(await harness.items()[ids[0]]).textContent == "neu")
    }

    // MARK: The setting (Q2, D3)

    /// Off: `deleteAll` once, the state gone, and no further call on later saves.
    @Test func turningOffDeletesEverythingOnceAndRemovesTheState() async throws {
        let harness = try SpotlightHarness()
        try SpotlightStore.insert(count: 3, in: harness.container)
        let passes = PassSignal()
        let indexer = harness.indexer(hooks: passes.hooks)
        defer { indexer.stop() }
        indexer.start()
        await passes.ended.wait()
        #expect(await harness.items().count == 3)
        await harness.index.clearCalls()

        await indexer.setEnabled(false)
        await passes.ended.wait(for: 2)
        #expect(!harness.setting.isEnabled)
        #expect(await harness.index.calls == [.deleteAll])
        #expect(await harness.items().isEmpty)
        #expect(harness.state.state == nil)

        try SpotlightStore.insert(count: 2, in: harness.container)
        await passes.ended.wait(for: 3)
        #expect(await indexer.reports.last?.outcome == .disabled)
        #expect(await harness.index.calls == [.deleteAll], "no call on a later save")
    }

    /// On again: a full pass.
    @Test func turningOnRunsAFullPass() async throws {
        let harness = try SpotlightHarness(setting: TestSpotlightSwitch(false))
        let ids = try SpotlightStore.insert(count: 3, in: harness.container)
        let indexer = harness.indexer()
        #expect(await indexer.runPass().outcome == .disabled)
        #expect(await harness.index.calls.isEmpty)

        await indexer.setEnabled(true)
        let report = await indexer.runPass()
        #expect(report.full != nil)
        #expect(Set(await harness.items().keys) == Set(ids))
        #expect(harness.setting.isEnabled)
    }

    /// Off while a pass is held inside its `index` call: the pass abandons its open batch (no `endBatch`, nothing
    /// committed) and writes no state, then `deleteAll` is called and the state removed.
    @Test func turningOffWhileAPassIsHeldStopsItWithoutWriting() async throws {
        let held = Checkpoint()
        defer { held.release() }
        let armed = Armed()
        let harness = try SpotlightHarness(
            index: InMemorySpotlightIndex(hook: { call in
                if call.operation == .index, armed.isOn { await held.pass() }
            }))
        try SpotlightStore.insert(count: 2, in: harness.container)
        let passes = PassSignal()
        let indexer = harness.indexer(hooks: passes.hooks)
        defer { indexer.stop() }
        indexer.start()
        await passes.ended.wait()
        let saves = harness.state.saves
        armed.turnOn()
        await harness.index.clearCalls()

        try SpotlightStore.insert(count: 1, in: harness.container)
        await held.reached()
        await indexer.setEnabled(false)
        held.release()
        await passes.ended.wait(for: 3)

        let reports = await indexer.reports
        #expect(reports[1].outcome == .stopped)
        #expect(harness.state.saves == saves, "the held pass wrote nothing")
        let calls = await harness.index.calls
        #expect(!calls.contains { $0.operation == .endBatch })
        #expect(
            calls.suffix(2) == [.abandonBatch, .deleteAll], "the begun batch is abandoned, then everything removed")
        #expect(await harness.index.batchViolations == 0)
        #expect(await harness.items().isEmpty)
        #expect(harness.state.state == nil)
    }

    /// The reviewer's probe `r226OffAndOnWhileHeldInIndex` (#226 review, B1): off and on again while a pass is held
    /// inside `index`, with its batch begun and not ended. The held pass abandons its batch, so the next passes can
    /// begin theirs (the in-memory index enforces the header's rule), and everything ends up indexed.
    @Test func offAndOnWhileAPassIsHeldInIndexIndexesEverything() async throws {
        let held = Checkpoint()
        defer { held.release() }
        let armed = Armed()
        let once = Armed()
        let harness = try SpotlightHarness(
            index: InMemorySpotlightIndex(hook: { call in
                if call.operation == .index, armed.isOn, !once.isOn {
                    once.turnOn()
                    await held.pass()
                }
            }))
        try SpotlightStore.insert(count: 2, in: harness.container)
        let passes = PassSignal()
        let indexer = harness.indexer(hooks: passes.hooks)
        defer { indexer.stop() }
        indexer.start()
        await passes.ended.wait()
        armed.turnOn()
        let ids = try SpotlightStore.insert(count: 1, in: harness.container)
        await held.reached()
        await indexer.setEnabled(false)
        await indexer.setEnabled(true)
        held.release()
        await passes.ended.wait(for: 3)
        let last = await indexer.reports.last
        #expect(last?.outcome == .done)
        #expect(await harness.items().count == 3)
        #expect(await harness.items()[ids[0]] != nil)
        #expect(await harness.index.batchViolations == 0)
    }

    /// The reviewer's probe `r226TextRowDeletedAlone` (#226 review, N1): a `DocumentText` deleted on its own nullifies
    /// `Document.text`, which the history records as a `Document` update in `text`; the item is pushed again with no
    /// text.
    @Test func aTextRowDeletedAloneEmptiesTheItemsText() async throws {
        let harness = try SpotlightHarness()
        let id = try SpotlightStore.insert(.init(title: "A", text: "alter Inhalt"), in: harness.container)
        let indexer = harness.indexer()
        await indexer.runPass()
        #expect(try #require(await harness.items()[id]).textContent == "alter Inhalt")
        try SpotlightStore.edit(id, in: harness.container) { document, context in
            if let text = document.text { context.delete(text) }
        }
        await harness.index.clearCalls()
        let report = await indexer.runPass()
        #expect(report.outcome == .done)
        #expect(await harness.pushed() == [id], "the deleted text row named its document")
        #expect(try #require(await harness.items()[id]).textContent == "")
    }

    /// A launch with the setting off after a failed delete deletes again.
    @Test func aLaunchWithTheSettingOffAfterAFailedDeleteDeletesAgain() async throws {
        let failing = HookSwitch()
        let harness = try SpotlightHarness(index: InMemorySpotlightIndex(hook: failing.hook))
        try SpotlightStore.insert(count: 2, in: harness.container)
        let indexer = harness.indexer()
        await indexer.runPass()
        failing.fail([.deleteAll])
        await indexer.setEnabled(false)
        #expect(await indexer.runPass().outcome == .failed)
        #expect(harness.state.state != nil, "kept, so the delete is tried again")
        #expect(await harness.items().count == 2)

        failing.clear()
        let nextLaunch = harness.indexer()
        #expect(await nextLaunch.runPass().outcome == .disabled)
        #expect(await harness.items().isEmpty)
        #expect(harness.state.state == nil)
    }

    /// A device without indexing: no call at all, and no state.
    @Test func anUnavailableIndexGetsNoCall() async throws {
        let harness = try SpotlightHarness(index: InMemorySpotlightIndex(isAvailable: false))
        try SpotlightStore.insert(count: 2, in: harness.container)
        let indexer = harness.indexer()
        #expect(await indexer.runPass().outcome == .unavailable)
        await indexer.setEnabled(false)
        #expect(await indexer.runPass().outcome == .unavailable)
        #expect(await harness.index.calls.isEmpty)
        #expect(harness.state.saves == 0)
        #expect(harness.state.removals == 0)
    }

    /// A requested identifier: pushed when live, deleted when gone (a stale result, part 2).
    @Test func aRefreshPushesALiveItemAndDeletesAGoneOne() async throws {
        let harness = try SpotlightHarness()
        let ids = try SpotlightStore.insert(count: 1, in: harness.container)
        let indexer = harness.indexer()
        await indexer.runPass()
        await harness.index.clearCalls()
        let gone = UUID()
        await indexer.refresh(identifiers: [ids[0], gone])
        await indexer.runPass()
        #expect(await harness.pushed() == [ids[0]])
        #expect(await harness.deleted() == [gone])
        await harness.index.clearCalls()
        await indexer.runPass()
        #expect(await harness.index.calls == [.lastClientState], "asked once")
    }
}
