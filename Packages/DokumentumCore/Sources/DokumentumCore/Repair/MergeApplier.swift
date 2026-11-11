import DokumentumKit
import Foundation
import SwiftData

/// Carries out one repair operation on the store's records: the same change `RepairPlan.apply` makes to a
/// snapshot (DokumentumKit), so the store ends where the planner's simulation ends (`RepairPassesTests`
/// compares both). The merge moves are ported from the predecessor's `MetadataMaintenance.merge(_:into:in:
/// recorder:)` (pklnx/document-archive), without its recorder, saved views and deadlines, which do not exist
/// here. The loser becomes a tombstone (`mergedIntoID`, `mergedAt`) instead of being deleted: nothing here
/// deletes a record (I1).
///
/// The caller checks each operation's precondition first: it applies only what `RepairPlan.apply` applied to
/// a snapshot read from these records in the same context, right before (I6).
enum MergeApplier {
    /// A record an applied operation names is not among the records read. The pass is not saved.
    struct MissingRecord: Error {
        let instanceID: UUID
    }

    static func apply(_ operation: RepairOperation, to records: RowRecords, now: Date) throws {
        switch operation {
        case .repoint(let reference, let from, let to):
            try repoint(reference, from: from, to: to, in: records, now: now)
        case .mergeMetadata(let kind, let loser, let keeper):
            try merge(kind, loser: loser, into: keeper, in: records, now: now)
        case .makeRoot(let tag, _):
            try require(records.tags[tag], tag).parent = nil
        case .relink(let blob, let document):
            let target = try require(records.documents[document], document)
            if let file = records.files[blob] {
                file.document = target
            } else if let thumbnail = records.thumbnails[blob] {
                thumbnail.document = target
            } else {
                try require(records.texts[blob], blob).document = target
            }
        case .revive(let tombstone):
            if let tag = records.tags[tombstone] {
                (tag.mergedIntoID, tag.mergedAt) = (nil, nil)
            } else if let correspondent = records.correspondents[tombstone] {
                (correspondent.mergedIntoID, correspondent.mergedAt) = (nil, nil)
            } else {
                let type = try require(records.documentTypes[tombstone], tombstone)
                (type.mergedIntoID, type.mergedAt) = (nil, nil)
            }
        }
    }

    private static func repoint(
        _ reference: RepairReference, from: UUID, to: UUID, in records: RowRecords, now: Date
    ) throws {
        switch reference {
        case .correspondent(let document):
            let document = try require(records.documents[document], document)
            document.correspondent = try require(records.correspondents[to], to)
            document.touch(now)
        case .documentType(let document):
            let document = try require(records.documents[document], document)
            document.documentType = try require(records.documentTypes[to], to)
            document.touch(now)
        case .tag(let document):
            // Remove and add in the same transaction (I3).
            let document = try require(records.documents[document], document)
            replaceTag(from, by: try require(records.tags[to], to), on: document)
            document.touch(now)
        case .parent(let tag):
            try require(records.tags[tag], tag).parent = try require(records.tags[to], to)
        }
    }

    private static func merge(
        _ kind: MetadataKind, loser: UUID, into keeper: UUID, in records: RowRecords, now: Date
    ) throws {
        switch kind {
        case .correspondent:
            let (source, target) = (
                try require(records.correspondents[loser], loser), try require(records.correspondents[keeper], keeper)
            )
            for document in records.documents.values where document.correspondent?.instanceID == loser {
                document.correspondent = target
                document.touch(now)
            }
            (source.mergedIntoID, source.mergedAt) = (target.id, now)
        case .documentType:
            let (source, target) = (
                try require(records.documentTypes[loser], loser), try require(records.documentTypes[keeper], keeper)
            )
            for document in records.documents.values where document.documentType?.instanceID == loser {
                document.documentType = target
                document.touch(now)
            }
            (source.mergedIntoID, source.mergedAt) = (target.id, now)
        case .tag:
            let (source, target) = (try require(records.tags[loser], loser), try require(records.tags[keeper], keeper))
            // Touched also when the document had the keeper already: it lost a tag.
            for document in records.documents.values
            where (document.tags ?? []).contains(where: { $0.instanceID == loser }) {
                replaceTag(loser, by: target, on: document)
                document.touch(now)
            }
            // Unconditionally, tombstones and the keeper included, as `RepairPlan.apply` does: pass 3, which runs
            // right after, breaks a cycle this closes, so only cycle breaking clears a parent (I3).
            for tag in records.tags.values where tag.parent?.instanceID == loser {
                tag.parent = target
            }
            (source.mergedIntoID, source.mergedAt) = (target.id, now)
        }
    }

    private static func replaceTag(_ old: UUID, by new: Tag, on document: Document) {
        var tags = document.tags ?? []
        tags.removeAll { $0.instanceID == old }
        if !tags.contains(where: { $0.instanceID == new.instanceID }) { tags.append(new) }
        document.tags = tags
    }

    private static func require<T>(_ record: T?, _ instanceID: UUID) throws -> T {
        guard let record else { throw MissingRecord(instanceID: instanceID) }
        return record
    }
}
