import Foundation

/// One broken invariant, with what broke it.
public struct RepairInvariantViolation: Hashable, Sendable, CustomStringConvertible {
    public enum Invariant: String, Hashable, Sendable {
        case i1, i2, i3, i4, i5, i8
    }

    public var invariant: Invariant
    public var detail: String

    public var description: String { "\(invariant.rawValue.uppercased()): \(detail)" }
}

/// The invariants of the repair (plan of #2, "Repair passes") that can be read from a before state, a plan
/// and an after state:
/// - I1, no deletes: the `instanceID`s of every entity are the same before and after.
/// - I2, references only to live, present targets: every operation's target, every changed reference.
/// - I3, no reference is dropped: only `makeRoot` may clear a reference, a removed tag has its live
///   replacement, and a blob's link never changes once set.
/// - I4, tombstone state comes from one place only: `mergeMetadata` sets it, `revive` clears it.
/// - I5, decisions use only immutable keys: immutable values stay, and every winner is the one
///   `keeperOrder` gives.
/// - I8, no fallback write-back: the frozen enums' raw values stay.
///
/// I6 and I7 need a store, so part 3 checks them there.
///
/// Independent of the planner: it shares only `RepairPlan.apply` and the chain walk, both to replay a
/// plan's decisions. A pure function, for planner tests here and for SwiftData repair tests, which build the
/// snapshots from their container.
public enum RepairInvariants {
    /// `plannedOnBefore: false` is for a plan that was made on another view of the data (a device that
    /// had not received everything): which winner the view saw cannot be judged on this state, so the
    /// replay of its decisions is left out.
    public static func violations(
        before: RepairSnapshot,
        plan: RepairPlan,
        after: RepairSnapshot,
        plannedOnBefore: Bool = true
    ) -> [RepairInvariantViolation] {
        var found = noDeletes(before: before, after: after)
        found += referenceTargets(before: before, plan: plan, after: after)
        found += noDroppedReferences(before: before, plan: plan, after: after)
        found += tombstoneState(before: before, plan: plan, after: after)
        found += immutableKeys(before: before, plan: plan, after: after)
        if plannedOnBefore {
            found += replayedDecisions(before: before, plan: plan)
        }
        found += frozenValues(before: before, after: after)
        return found
    }

    // MARK: I1

    private static func noDeletes(before: RepairSnapshot, after: RepairSnapshot) -> [RepairInvariantViolation] {
        func compare(_ entity: String, _ old: [UUID], _ new: [UUID]) -> [RepairInvariantViolation] {
            let (oldSet, newSet) = (Set(old), Set(new))
            var found = oldSet.subtracting(newSet).map {
                RepairInvariantViolation(invariant: .i1, detail: "\(entity) \($0) vanished")
            }
            found += newSet.subtracting(oldSet).map {
                RepairInvariantViolation(invariant: .i1, detail: "\(entity) \($0) appeared")
            }
            return found
        }
        var found = compare("document", before.documents.map(\.instanceID), after.documents.map(\.instanceID))
        for kind in MetadataKind.allCases {
            found += compare(
                kind.rawValue,
                before.metadata.filter { $0.kind == kind }.map(\.instanceID),
                after.metadata.filter { $0.kind == kind }.map(\.instanceID)
            )
        }
        for kind in BlobKind.allCases {
            found += compare(
                kind.rawValue,
                before.blobs.filter { $0.kind == kind }.map(\.instanceID),
                after.blobs.filter { $0.kind == kind }.map(\.instanceID)
            )
        }
        return found
    }

    // MARK: I2

    private static func referenceTargets(
        before: RepairSnapshot,
        plan: RepairPlan,
        after: RepairSnapshot
    ) -> [RepairInvariantViolation] {
        var found: [RepairInvariantViolation] = []
        let beforeRecords = records(before)
        let afterRecords = records(after)

        func check(_ target: UUID, kind: MetadataKind, in table: [UUID: MetadataSnapshot], _ what: String) {
            guard let record = table[target] else {
                found.append(.init(invariant: .i2, detail: "\(what) \(target) is not present"))
                return
            }
            if !record.isLive {
                found.append(.init(invariant: .i2, detail: "\(what) \(target) is a tombstone"))
            }
            if record.kind != kind {
                found.append(.init(invariant: .i2, detail: "\(what) \(target) is a \(record.kind.rawValue)"))
            }
        }

        // The operations: every target was live and present when planned. Revival comes last in a plan,
        // so a target cannot have needed it.
        for operation in plan.operations {
            switch operation {
            case .repoint(let reference, _, let to):
                check(to, kind: kind(of: reference), in: beforeRecords, "re-point target")
            case .mergeMetadata(let kind, _, let keeper):
                check(keeper, kind: kind, in: beforeRecords, "merge target")
            case .relink(_, let document):
                if !before.documents.contains(where: { $0.instanceID == document }) {
                    found.append(.init(invariant: .i2, detail: "relink target \(document) is not present"))
                }
            case .makeRoot, .revive:
                break
            }
        }

        // The result: every reference that changed points at a live, present record.
        let beforeDocuments = Dictionary(before.documents.map { ($0.instanceID, $0) }, uniquingKeysWith: { a, _ in a })
        for document in after.documents {
            let old = beforeDocuments[document.instanceID]
            if let new = document.correspondent, new != old?.correspondent {
                check(new, kind: .correspondent, in: afterRecords, "correspondent")
            }
            if let new = document.documentType, new != old?.documentType {
                check(new, kind: .documentType, in: afterRecords, "document type")
            }
            for new in document.tags.subtracting(old?.tags ?? []) {
                check(new, kind: .tag, in: afterRecords, "tag")
            }
        }
        for tag in after.metadata {
            if let new = tag.parentInstanceID, new != beforeRecords[tag.instanceID]?.parentInstanceID {
                check(new, kind: .tag, in: afterRecords, "parent")
            }
        }
        let beforeBlobs = Dictionary(before.blobs.map { ($0.instanceID, $0) }, uniquingKeysWith: { a, _ in a })
        let presentDocuments = Set(after.documents.map(\.instanceID))
        for blob in after.blobs {
            if let new = blob.linkedDocumentInstanceID, new != beforeBlobs[blob.instanceID]?.linkedDocumentInstanceID,
                !presentDocuments.contains(new)
            {
                found.append(.init(invariant: .i2, detail: "blob \(blob.instanceID) linked to absent \(new)"))
            }
        }
        return found
    }

    private static func kind(of reference: RepairReference) -> MetadataKind {
        switch reference {
        case .correspondent: .correspondent
        case .documentType: .documentType
        case .tag, .parent: .tag
        }
    }

    // MARK: I3

    private static func noDroppedReferences(
        before: RepairSnapshot,
        plan: RepairPlan,
        after: RepairSnapshot
    ) -> [RepairInvariantViolation] {
        var found: [RepairInvariantViolation] = []
        let afterDocuments = Dictionary(after.documents.map { ($0.instanceID, $0) }, uniquingKeysWith: { a, _ in a })
        for old in before.documents {
            guard let new = afterDocuments[old.instanceID] else { continue }
            if old.correspondent != nil, new.correspondent == nil {
                found.append(.init(invariant: .i3, detail: "document \(old.instanceID) lost its correspondent"))
            }
            if old.documentType != nil, new.documentType == nil {
                found.append(.init(invariant: .i3, detail: "document \(old.instanceID) lost its document type"))
            }
            for removed in old.tags.subtracting(new.tags) {
                let replacements = replacements(of: removed, before: before, after: after)
                let isReplaced = new.tags.contains { replacements.contains($0) }
                if !isReplaced {
                    found.append(.init(invariant: .i3, detail: "document \(old.instanceID) lost tag \(removed)"))
                }
            }
        }

        var cleared: Set<UUID> = []
        for case .makeRoot(let tag, _) in plan.operations { cleared.insert(tag) }
        let afterRecords = records(after)
        for old in before.metadata where old.parentInstanceID != nil {
            if let new = afterRecords[old.instanceID], new.parentInstanceID == nil, !cleared.contains(old.instanceID) {
                found.append(.init(invariant: .i3, detail: "tag \(old.instanceID) lost its parent without makeRoot"))
            }
        }
        let afterBlobs = Dictionary(after.blobs.map { ($0.instanceID, $0) }, uniquingKeysWith: { a, _ in a })
        for old in before.blobs {
            guard let link = old.linkedDocumentInstanceID, let new = afterBlobs[old.instanceID] else { continue }
            if new.linkedDocumentInstanceID != link {
                found.append(.init(invariant: .i3, detail: "blob \(old.instanceID) changed its link"))
            }
        }
        return found
    }

    /// The live records a removed tag may have been replaced by: every record a `mergedIntoID` leads to,
    /// before or after the plan. All of them, not just the one a chain follows now: records can share an
    /// `id`, and which of them comes first changes with a merge or a revival in the same plan.
    private static func replacements(of tag: UUID, before: RepairSnapshot, after: RepairSnapshot) -> Set<UUID> {
        let (old, new) = (records(before), records(after))
        var seen: Set<UUID> = [tag]
        var pending = [tag]
        var live: Set<UUID> = []
        while let current = pending.popLast() {
            let targets = [old[current]?.mergedIntoID, new[current]?.mergedIntoID].compactMap(\.self)
            guard let kind = new[current]?.kind else { continue }
            for record in after.metadata where record.kind == kind && targets.contains(record.id) {
                if record.isLive { live.insert(record.instanceID) }
                if seen.insert(record.instanceID).inserted { pending.append(record.instanceID) }
            }
        }
        return live
    }

    // MARK: I4

    private static func tombstoneState(
        before: RepairSnapshot,
        plan: RepairPlan,
        after: RepairSnapshot
    ) -> [RepairInvariantViolation] {
        var found: [RepairInvariantViolation] = []
        var merged: [UUID: UUID] = [:]
        var revived: Set<UUID> = []
        for operation in plan.operations {
            switch operation {
            case .mergeMetadata(_, let loser, let keeper): merged[loser] = keeper
            case .revive(let tombstone): revived.insert(tombstone)
            case .repoint, .makeRoot, .relink: break
            }
        }
        let afterRecords = records(after)
        let beforeRecords = records(before)
        for old in before.metadata {
            guard let new = afterRecords[old.instanceID] else { continue }
            guard old.mergedIntoID != new.mergedIntoID || old.mergedAt != new.mergedAt else { continue }
            if old.isLive, !new.isLive, let keeper = merged[old.instanceID] {
                if beforeRecords[keeper]?.id != new.mergedIntoID {
                    found.append(.init(invariant: .i4, detail: "\(old.instanceID) merged into the wrong id"))
                }
            } else if !old.isLive, new.isLive, new.mergedAt == nil, revived.contains(old.instanceID) {
                continue
            } else {
                found.append(.init(invariant: .i4, detail: "\(old.instanceID) changed tombstone state on its own"))
            }
        }
        return found
    }

    // MARK: I5

    private static func immutableKeys(
        before: RepairSnapshot,
        plan: RepairPlan,
        after: RepairSnapshot
    ) -> [RepairInvariantViolation] {
        var found: [RepairInvariantViolation] = []
        let afterDocuments = Dictionary(after.documents.map { ($0.instanceID, $0) }, uniquingKeysWith: { a, _ in a })
        for old in before.documents {
            if let new = afterDocuments[old.instanceID], new.id != old.id || new.createdAt != old.createdAt {
                found.append(.init(invariant: .i5, detail: "document \(old.instanceID) changed an immutable key"))
            }
        }
        let afterRecords = records(after)
        for old in before.metadata {
            if let new = afterRecords[old.instanceID],
                new.id != old.id || new.createdAt != old.createdAt || new.kind != old.kind || new.name != old.name
            {
                found.append(.init(invariant: .i5, detail: "\(old.instanceID) changed an immutable key"))
            }
        }
        let afterBlobs = Dictionary(after.blobs.map { ($0.instanceID, $0) }, uniquingKeysWith: { a, _ in a })
        for old in before.blobs {
            if let new = afterBlobs[old.instanceID],
                new.documentID != old.documentID || new.createdAt != old.createdAt || new.kind != old.kind
            {
                found.append(.init(invariant: .i5, detail: "blob \(old.instanceID) changed an immutable key"))
            }
        }
        let beforeRecords = records(before)
        for case .mergeMetadata(_, let loser, let keeper) in plan.operations {
            if let loser = beforeRecords[loser], let keeper = beforeRecords[keeper],
                !RepairPlanner.precedes(keeper, loser)
            {
                found.append(.init(invariant: .i5, detail: "keeper \(keeper.instanceID) is not the older record"))
            }
        }
        return found
    }

    /// Replays the plan on the state it was made for, and checks each decision on the state at that step.
    private static func replayedDecisions(before: RepairSnapshot, plan: RepairPlan) -> [RepairInvariantViolation] {
        var found: [RepairInvariantViolation] = []
        var state = before
        for operation in plan.operations {
            if let problem = decisionProblem(operation, in: state) {
                found.append(.init(invariant: .i5, detail: problem))
            }
            state = RepairPlan([operation]).apply(to: state, now: Date(timeIntervalSince1970: 0)).snapshot
        }
        return found
    }

    private static func decisionProblem(_ operation: RepairOperation, in state: RepairSnapshot) -> String? {
        switch operation {
        case .repoint(_, let from, let to):
            let end = RepairPlanner.chainEnd(of: from, in: state)
            return end == .live(to) ? nil : "re-pointed \(from) to \(to), but its chain ends elsewhere"
        case .mergeMetadata:
            return nil  // `immutableKeys` checks the winner.
        case .makeRoot(let tag, _):
            return cycleProblem(tag, in: state)
        case .relink(let blob, let document):
            return relinkProblem(blob, to: document, in: state)
        case .revive(let tombstone):
            switch RepairPlanner.chainEnd(of: tombstone, in: state) {
            case .loop(let minimum): return minimum == tombstone ? nil : "revived \(tombstone), not the loop's minimum"
            case .missing(let last): return last == tombstone ? nil : "revived \(tombstone), not the chain's last"
            case .live, nil: return "revived \(tombstone), which has no loop or missing end"
            }
        }
    }

    private static func cycleProblem(_ tag: UUID, in state: RepairSnapshot) -> String? {
        let live = Dictionary(
            state.metadata.filter { $0.kind == .tag && $0.isLive }.map { ($0.instanceID, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        guard let start = live[tag] else { return "made \(tag) a root, which is not a live tag" }
        var cycle = [start]
        var current = start.parentInstanceID.flatMap { live[$0] }
        while let next = current, next.instanceID != tag, !cycle.contains(next) {
            cycle.append(next)
            current = next.parentInstanceID.flatMap { live[$0] }
        }
        guard current?.instanceID == tag else { return "made \(tag) a root, which is not in a cycle" }
        return RepairPlanner.keeperOrder(cycle)[0].instanceID == tag
            ? nil : "made \(tag) a root, not its cycle's oldest"
    }

    private static func relinkProblem(_ blob: UUID, to document: UUID, in state: RepairSnapshot) -> String? {
        guard let record = state.blobs.first(where: { $0.instanceID == blob }) else {
            return "relinked \(blob), which is not present"
        }
        let rivals = state.blobs.filter {
            $0.kind == record.kind && $0.linkedDocumentInstanceID == nil && $0.documentID == record.documentID
        }
        guard RepairPlanner.keeperOrder(rivals).first?.instanceID == blob else {
            return "relinked \(blob), not the oldest unlinked blob"
        }
        let taken = Set(state.blobs.filter { $0.kind == record.kind }.compactMap(\.linkedDocumentInstanceID))
            .union(state.documents.filter { $0.linkedBlobs.contains(record.kind) }.map(\.instanceID))
        let free = state.documents.filter { $0.id == record.documentID && !taken.contains($0.instanceID) }
        return RepairPlanner.keeperOrder(free).first?.instanceID == document
            ? nil : "relinked \(blob) to \(document), not the oldest free document"
    }

    // MARK: I8

    private static func frozenValues(before: RepairSnapshot, after: RepairSnapshot) -> [RepairInvariantViolation] {
        let afterDocuments = Dictionary(after.documents.map { ($0.instanceID, $0) }, uniquingKeysWith: { a, _ in a })
        return before.documents.compactMap { old in
            guard let new = afterDocuments[old.instanceID],
                new.sourceRaw != old.sourceRaw || new.textSourceRaw != old.textSourceRaw
                    || new.processingStateRaw != old.processingStateRaw
            else { return nil }
            return .init(invariant: .i8, detail: "document \(old.instanceID) changed a frozen raw value")
        }
    }

    private static func records(_ snapshot: RepairSnapshot) -> [UUID: MetadataSnapshot] {
        Dictionary(snapshot.metadata.map { ($0.instanceID, $0) }, uniquingKeysWith: { first, _ in first })
    }
}
