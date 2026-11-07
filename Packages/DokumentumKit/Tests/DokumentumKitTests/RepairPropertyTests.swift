import DokumentumKit
import Foundation
import Testing

/// Random states with tombstones and merge chains (loops and missing ends included), shared `id`s, cycles,
/// missing records and relationships, and files and thumbnails (orphans, early arrivals, doubles).
private struct StateGenerator {
    var random: SeededGenerator
    private var nextInstance = 1

    init(seed: Int) {
        random = SeededGenerator(seed: seed)
    }

    private mutating func chance(_ percent: Int) -> Bool {
        Int.random(in: 0..<100, using: &random) < percent
    }

    private mutating func pick<T>(_ items: [T]) -> T? {
        items.randomElement(using: &random)
    }

    private mutating func instance() -> UUID {
        // Not in order of creation, so that the instanceID says nothing about the date.
        nextInstance += 1
        return uuid(nextInstance * 7919 % 100_003)
    }

    /// Few dates, so that ties are common.
    private mutating func date() -> Date {
        at(Int.random(in: 1...4, using: &random) * days)
    }

    private mutating func mergedAt() -> Date? {
        pick([nil, planningTime, planningTime.addingTimeInterval(TimeInterval(-40 * days))]) ?? nil
    }

    private static let names = ["Auto", "auto ", "AUTO", "Golf", "Müller", "Muller", "", "  ", "Polo"]

    private mutating func records(_ kind: MetadataKind, count: Int) -> [MetadataSnapshot] {
        var records: [MetadataSnapshot] = []
        for _ in 0..<count {
            let shared = chance(15) ? pick(records)?.id : nil
            records.append(
                MetadataSnapshot(
                    kind: kind,
                    instanceID: instance(),
                    id: shared ?? instance(),
                    createdAt: date(),
                    name: pick(Self.names) ?? "",
                )
            )
        }
        let ids = records.map(\.id)
        for index in records.indices where chance(35) {
            // A record of this kind, itself included, or something that is not here.
            let target = chance(25) ? uuid(999_000 + Int.random(in: 0..<3, using: &random)) : (pick(ids) ?? uuid(0))
            records[index].mergedIntoID = target
            records[index].mergedAt = mergedAt()
        }
        return records
    }

    mutating func state() -> RepairSnapshot {
        let correspondents = records(.correspondent, count: Int.random(in: 0...5, using: &random))
        let types = records(.documentType, count: Int.random(in: 0...3, using: &random))
        var tags = records(.tag, count: Int.random(in: 0...7, using: &random))
        let tagIDs = tags.map(\.instanceID)
        for index in tags.indices where chance(60) {
            tags[index].parentInstanceID = pick(tagIDs)
        }

        var documents: [DocumentSnapshot] = []
        for _ in 0..<Int.random(in: 0...5, using: &random) {
            let shared = chance(15) ? pick(documents)?.id : nil
            var document = DocumentSnapshot(
                instanceID: instance(),
                id: shared ?? instance(),
                createdAt: date(),
                modifiedAt: date()
            )
            document.correspondent = chance(70) ? pick(correspondents)?.instanceID : nil
            document.documentType = chance(50) ? pick(types)?.instanceID : nil
            document.tags = Set(tagIDs.filter { _ in chance(30) })
            document.sourceRaw = pick(["file", "scan", "fax"]) ?? "file"
            document.textSourceRaw = pick(["", "vision", "braille"]) ?? ""
            document.processingStateRaw = pick(["pending", "done", "queued"]) ?? "pending"
            documents.append(document)
        }

        var blobs: [BlobSnapshot] = []
        for _ in 0..<Int.random(in: 0...6, using: &random) {
            let owner = pick(documents)
            var blob = BlobSnapshot(
                kind: chance(50) ? .file : .thumbnail,
                instanceID: instance(),
                createdAt: date(),
                documentID: chance(70) ? owner?.id : (chance(50) ? uuid(998_000) : nil)
            )
            if chance(40), blob.documentID == owner?.id {
                blob.linkedDocumentInstanceID = owner?.instanceID
            }
            blobs.append(blob)
        }
        return RepairSnapshot(documents: documents, metadata: correspondents + types + tags, blobs: blobs)
    }

    /// Records and relationships missing, and newer `modifiedAt`s.
    mutating func view(of state: RepairSnapshot) -> RepairSnapshot {
        var result = DokumentumKitTests.view(
            of: state,
            droppingMetadata: Set(state.metadata.map(\.instanceID).filter { _ in chance(20) }),
            documents: Set(state.documents.map(\.instanceID).filter { _ in chance(20) }),
            blobs: Set(state.blobs.map(\.instanceID).filter { _ in chance(20) })
        )
        for index in result.documents.indices {
            if chance(10) { result.documents[index].correspondent = nil }
            if chance(10) { result.documents[index].documentType = nil }
            if chance(10) { result.documents[index].tags = [] }
            if chance(50) { result.documents[index].modifiedAt = planningTime }
        }
        for index in result.metadata.indices where chance(10) {
            result.metadata[index].parentInstanceID = nil
        }
        for index in result.blobs.indices where chance(10) {
            result.blobs[index].linkedDocumentInstanceID = nil
        }
        return result
    }
}

private let seeds = 0..<500

struct RepairPropertyTests {
    /// A generator that never makes a loop proves nothing about loops.
    @Test func theGeneratorReachesEveryCase() {
        var operations: Set<String> = []
        var ends: Set<String> = []
        var counts = RepairCounts()
        for seed in seeds {
            var generator = StateGenerator(seed: seed)
            let state = generator.state()
            let plan = RepairPlanner.plan(state, context: settledContext)
            operations.formUnion(plan.operations.map(namesARepairOperation))
            for record in state.metadata where !record.isLive {
                switch RepairPlanner.chainEnd(of: record.instanceID, in: state) {
                case .live: ends.insert("live")
                case .missing: ends.insert("missing")
                case .loop: ends.insert("loop")
                case nil: break
                }
            }
            let found = RepairPlanner.counts(in: state)
            counts.orphanFiles += found.orphanFiles
            counts.orphanThumbnails += found.orphanThumbnails
            counts.documentsWithTwoFiles += found.documentsWithTwoFiles
            counts.documentsWithTwoThumbnails += found.documentsWithTwoThumbnails
            counts.idGroupsWithSeveralRecords += found.idGroupsWithSeveralRecords
            counts.tombstones += found.tombstones
        }
        #expect(operations == ["repoint", "mergeMetadata", "makeRoot", "relink", "revive"])
        #expect(ends == ["live", "missing", "loop"])
        #expect(counts.orphanFiles > 0)
        #expect(counts.orphanThumbnails > 0)
        #expect(counts.documentsWithTwoFiles > 0)
        #expect(counts.documentsWithTwoThumbnails > 0)
        #expect(counts.idGroupsWithSeveralRecords > 0)
        #expect(counts.tombstones > 0)
    }

    @Test func everyPlanKeepsTheInvariants() {
        for seed in seeds {
            var generator = StateGenerator(seed: seed)
            let state = generator.state()
            let plan = RepairPlanner.plan(state, context: settledContext)
            let application = plan.apply(to: state, now: planningTime)
            #expect(application.skipped.isEmpty, "seed \(seed)")
            let violations = RepairInvariants.violations(before: state, plan: plan, after: application.snapshot)
            #expect(violations.isEmpty, "seed \(seed): \(violations)")
        }
    }

    @Test func aRunWithoutARevivalLeavesNothingForTheNextRun() {
        for seed in seeds {
            var generator = StateGenerator(seed: seed)
            let state = generator.state()
            let plan = RepairPlanner.plan(state, context: settledContext)
            let revives = plan.operations.contains { if case .revive = $0 { true } else { false } }
            guard !revives else { continue }
            let after = plan.apply(to: state, now: planningTime).snapshot
            #expect(RepairPlanner.plan(after, context: settledContext).isEmpty, "seed \(seed)")
        }
    }

    @Test func everyStateSettles() {
        for seed in seeds {
            var generator = StateGenerator(seed: seed)
            let state = generator.state()
            guard let end = state.settled() else {
                Issue.record("seed \(seed) has no fixpoint")
                continue
            }
            #expect(RepairPlanner.plan(end, context: settledContext).isEmpty, "seed \(seed)")
            #expect(Set(end.metadata.map(\.instanceID)) == Set(state.metadata.map(\.instanceID)), "seed \(seed)")
        }
    }

    @Test func theInputOrderChangesNoPlan() {
        for seed in seeds {
            var generator = StateGenerator(seed: seed)
            let state = generator.state()
            let plan = RepairPlanner.plan(state, context: settledContext)
            var random = SeededGenerator(seed: seed)
            for _ in 0..<5 {
                let shuffled = RepairSnapshot(
                    documents: state.documents.shuffled(using: &random),
                    metadata: state.metadata.shuffled(using: &random),
                    blobs: state.blobs.shuffled(using: &random)
                )
                #expect(RepairPlanner.plan(shuffled, context: settledContext) == plan, "seed \(seed)")
            }
        }
    }

    @Test func aNewerModifiedAtChangesNoPlan() {
        for seed in seeds {
            var generator = StateGenerator(seed: seed)
            let state = generator.state()
            var newer = state
            for index in newer.documents.indices {
                newer.documents[index].modifiedAt = at(500 - index)
            }
            let plan = RepairPlanner.plan(state, context: settledContext)
            #expect(RepairPlanner.plan(newer, context: settledContext) == plan, "seed \(seed)")
        }
    }

    @Test func plansOnTwoDivergentViewsHoldOnTheirViewsAndOnTheUnion() {
        for seed in seeds {
            var generator = StateGenerator(seed: seed)
            let union = generator.state()
            let views = [generator.view(of: union), generator.view(of: union)]
            let plans = views.map { RepairPlanner.plan($0, context: settledContext) }

            for (view, plan) in zip(views, plans) {
                let application = plan.apply(to: view, now: planningTime)
                #expect(application.skipped.isEmpty, "seed \(seed)")
                let violations = RepairInvariants.violations(before: view, plan: plan, after: application.snapshot)
                #expect(violations.isEmpty, "seed \(seed): \(violations)")
            }

            let after = checkedUnion(of: union, plans: plans)
            _ = checkedUnion(of: union, plans: plans.reversed())
            guard let end = after.settled() else {
                Issue.record("seed \(seed) has no fixpoint on the union")
                continue
            }
            #expect(RepairPlanner.breakCycles(in: end).isEmpty, "seed \(seed)")
            #expect(RepairPlanner.mergeSameNames(in: end).isEmpty, "seed \(seed)")
        }
    }
}
