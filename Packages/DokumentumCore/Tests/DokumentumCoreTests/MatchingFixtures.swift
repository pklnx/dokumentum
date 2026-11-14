import DokumentumKit
import Foundation
import SwiftData
import Synchronization
import Testing

@testable import DokumentumCore

// The matching tests' tools (#10, part 1b): records with rules, links set by another context, the matching fields
// of a document. The store's saves are counted by `SaveCounter` (`DocumentImporterTests`).

/// The matching budget of the Core tests: a clock no runner's load reaches, so an ordinary rule never times out in a
/// test (review A of #205, B4). Tests of a time-out pass `.progressCallbacks` with bounded inputs instead.
let testMatchingBudget = MatchingBudget.clock(.seconds(10))

/// What the rules can change on a document, by name, as the tests compare it.
struct MatchedRow: Equatable {
    var correspondent: String?
    var documentType: String?
    var tags: [String]
    var modifiedAt: Date
}

extension ProcessingStore {
    /// Inserts a live tag, correspondent or type with a rule (or a tombstone with `mergedInto`).
    @discardableResult
    func insertRule(
        _ kind: MetadataKind, _ name: String, _ mode: MatchMode, _ pattern: String, mergedInto: UUID? = nil
    ) throws -> UUID {
        let id = try insertMetadata(kind, name, mergedInto: mergedInto)
        try setRule(kind, id, mode, pattern)
        return id
    }

    /// Sets a record's rule in a context of its own: another save.
    func setRule(_ kind: MetadataKind, _ id: UUID, _ mode: MatchMode, _ pattern: String) throws {
        let context = ModelContext(container)
        let record = try #require(try Self.record(kind, id, in: context))
        record.matchMode = mode
        record.matchPattern = pattern
        try context.save()
    }

    /// Sets a record's stored mode string as a newer build would.
    func setRawMode(_ kind: MetadataKind, _ id: UUID, _ raw: String) throws {
        let context = ModelContext(container)
        let record = try #require(try Self.record(kind, id, in: context))
        switch record {
        case let tag as DokumentumCore.Tag: tag.matchModeRaw = raw
        case let correspondent as Correspondent: correspondent.matchModeRaw = raw
        case let type as DocumentType: type.matchModeRaw = raw
        default: Issue.record("unexpected record")
        }
        try context.save()
    }

    func rawRule(_ kind: MetadataKind, _ id: UUID) throws -> (mode: String, pattern: String)? {
        let context = ModelContext(container)
        switch try Self.record(kind, id, in: context) {
        case let tag as DokumentumCore.Tag: return (tag.matchModeRaw, tag.matchPattern)
        case let correspondent as Correspondent: return (correspondent.matchModeRaw, correspondent.matchPattern)
        case let type as DocumentType: return (type.matchModeRaw, type.matchPattern)
        default: return nil
        }
    }

    static func record(_ kind: MetadataKind, _ id: UUID, in context: ModelContext) throws -> (any MatchingRuleRecord)? {
        switch kind {
        case .tag:
            try context.fetch(FetchDescriptor<DokumentumCore.Tag>(predicate: #Predicate { $0.instanceID == id })).first
        case .correspondent:
            try context.fetch(FetchDescriptor<Correspondent>(predicate: #Predicate { $0.instanceID == id })).first
        case .documentType:
            try context.fetch(FetchDescriptor<DocumentType>(predicate: #Predicate { $0.instanceID == id })).first
        }
    }

    /// Links a correspondent, type or tag to the document in another context, without `touch()`: as an earlier
    /// fill or another device left it.
    func link(_ id: UUID, _ kind: MetadataKind, _ record: UUID) throws {
        try edit(id) { document, context in
            switch kind {
            case .tag:
                let tag = try #require(
                    try context.fetch(
                        FetchDescriptor<DokumentumCore.Tag>(predicate: #Predicate { $0.instanceID == record })
                    ).first)
                document.tags = (document.tags ?? []) + [tag]
            case .correspondent:
                document.correspondent = try #require(
                    try context.fetch(FetchDescriptor<Correspondent>(predicate: #Predicate { $0.instanceID == record }))
                        .first)
            case .documentType:
                document.documentType = try #require(
                    try context.fetch(FetchDescriptor<DocumentType>(predicate: #Predicate { $0.instanceID == record }))
                        .first)
            }
        }
    }

    /// Two correspondents sharing an `instanceID`, both with the rule `any` "Stadtwerke" and the name "Stadtwerke"
    /// (review A of #205, B1), the original inserted first. With `tombstoneFirst` the original is a merge's loser and its
    /// copy is live; otherwise both are live and the copy is older (first in keeper order). Without `copyHasRule` only
    /// the original has the rule.
    @discardableResult
    func insertCopiedCorrespondent(tombstoneFirst: Bool, copyHasRule: Bool = true) throws -> UUID {
        let keeper = try insertMetadata(.correspondent, "Stadtwerke GmbH")
        let context = ModelContext(container)
        let original = Correspondent(name: "Stadtwerke", createdAt: processingStart.addingTimeInterval(-hour))
        original.matchMode = .any
        original.matchPattern = "Stadtwerke"
        if tombstoneFirst {
            original.mergedIntoID = keeper
            original.mergedAt = processingStart
        }
        context.insert(original)
        try context.save()
        let copy = Correspondent(
            name: "Stadtwerke", createdAt: processingStart.addingTimeInterval(tombstoneFirst ? -hour : -2 * hour))
        copy.instanceID = original.instanceID
        if copyHasRule {
            copy.matchMode = .any
            copy.matchPattern = "Stadtwerke"
        }
        context.insert(copy)
        try context.save()
        return original.instanceID
    }

    /// Two live records of `kind` named `name` sharing one `instanceID` (a copied record, #207), with distinct `id`s,
    /// each saved on its own so the store returns the first one first: the second is younger by `gap` (negative:
    /// older). With `rule` both carry it. Returns the shared `instanceID` and both rows' `id`s, in insertion order.
    @discardableResult
    func insertCopies(
        _ kind: MetadataKind, _ name: String, gap: TimeInterval = 60, rule: (MatchMode, String)? = nil
    ) throws -> (instanceID: UUID, first: UUID, second: UUID) {
        switch kind {
        case .tag:
            try insertPair({ DokumentumCore.Tag(name: name, createdAt: $0) }, \.instanceID, \.id, gap: gap, rule: rule)
        case .correspondent:
            try insertPair({ Correspondent(name: name, createdAt: $0) }, \.instanceID, \.id, gap: gap, rule: rule)
        case .documentType:
            try insertPair({ DocumentType(name: name, createdAt: $0) }, \.instanceID, \.id, gap: gap, rule: rule)
        }
    }

    private func insertPair<T: MatchingRuleRecord & PersistentModel>(
        _ make: (Date) -> T, _ instanceID: ReferenceWritableKeyPath<T, UUID>, _ id: KeyPath<T, UUID>,
        gap: TimeInterval, rule: (MatchMode, String)?
    ) throws -> (instanceID: UUID, first: UUID, second: UUID) {
        let created = processingStart.addingTimeInterval(-hour)
        let context = ModelContext(container)
        func record(_ createdAt: Date) -> T {
            let record = make(createdAt)
            if let (mode, pattern) = rule {
                record.matchMode = mode
                record.matchPattern = pattern
            }
            return record
        }
        let first = record(created)
        context.insert(first)
        try context.save()
        let second = record(created.addingTimeInterval(gap))
        second[keyPath: instanceID] = first[keyPath: instanceID]
        context.insert(second)
        try context.save()
        return (first[keyPath: instanceID], first[keyPath: id], second[keyPath: id])
    }

    /// Links the row with `id` (one copy of a record with copies) to the document in another context, without
    /// `touch()`.
    func linkCopy(_ document: UUID, _ kind: MetadataKind, row id: UUID) throws {
        try edit(document) { document, context in
            switch kind {
            case .tag:
                let tag = try #require(
                    try context.fetch(FetchDescriptor<DokumentumCore.Tag>(predicate: #Predicate { $0.id == id })).first)
                document.tags = (document.tags ?? []) + [tag]
            case .correspondent:
                document.correspondent = try #require(
                    try context.fetch(FetchDescriptor<Correspondent>(predicate: #Predicate { $0.id == id })).first)
            case .documentType:
                document.documentType = try #require(
                    try context.fetch(FetchDescriptor<DocumentType>(predicate: #Predicate { $0.id == id })).first)
            }
        }
    }

    /// Makes the row with `id` (one copy of a record with copies) a merge's tombstone of the record `target` (an
    /// `instanceID`), in a context of its own: a merge's loser next to its live copy (#205's B1 shape).
    func mergeCopy(_ kind: MetadataKind, row id: UUID, into target: UUID) throws {
        let context = ModelContext(container)
        switch kind {
        case .tag:
            let into = try #require(
                try context.fetch(
                    FetchDescriptor<DokumentumCore.Tag>(predicate: #Predicate { $0.instanceID == target })
                )
                .first)
            let record = try #require(
                try context.fetch(FetchDescriptor<DokumentumCore.Tag>(predicate: #Predicate { $0.id == id })).first)
            (record.mergedIntoID, record.mergedAt) = (into.id, processingStart)
        case .correspondent:
            let into = try #require(
                try context.fetch(FetchDescriptor<Correspondent>(predicate: #Predicate { $0.instanceID == target }))
                    .first)
            let record = try #require(
                try context.fetch(FetchDescriptor<Correspondent>(predicate: #Predicate { $0.id == id })).first)
            (record.mergedIntoID, record.mergedAt) = (into.id, processingStart)
        case .documentType:
            let into = try #require(
                try context.fetch(FetchDescriptor<DocumentType>(predicate: #Predicate { $0.instanceID == target }))
                    .first)
            let record = try #require(
                try context.fetch(FetchDescriptor<DocumentType>(predicate: #Predicate { $0.id == id })).first)
            (record.mergedIntoID, record.mergedAt) = (into.id, processingStart)
        }
        try context.save()
    }

    /// The `id`s of the rows of `kind` the document links.
    func linkedRows(_ document: UUID, _ kind: MetadataKind) throws -> [UUID] {
        let row = try #require(try Self.fetch(document, in: ModelContext(container)))
        switch kind {
        case .tag: return (row.tags ?? []).map(\.id).sorted { $0.uuidString < $1.uuidString }
        case .correspondent: return row.correspondent.map { [$0.id] } ?? []
        case .documentType: return row.documentType.map { [$0.id] } ?? []
        }
    }

    /// A document in `stateRaw` with `text` in its text record, never edited.
    @discardableResult
    func insertWithText(
        _ text: String, title: String = "Document", stateRaw: String = "done", trashed: Bool = false,
        created: Date = processingStart
    ) throws -> UUID {
        let id = try insert(
            title: title, created: created, stateRaw: stateRaw, device: deviceA, claimedAt: processingStart,
            trashed: trashed, textSource: .pdfText)
        try edit(id) { document, _ in document.text?.extractedText = text }
        return id
    }

    func matched(_ id: UUID) throws -> MatchedRow {
        let document = try #require(try Self.fetch(id, in: ModelContext(container)))
        return MatchedRow(
            correspondent: document.correspondent?.name, documentType: document.documentType?.name,
            tags: (document.tags ?? []).map(\.name).sorted(), modifiedAt: document.modifiedAt)
    }

    /// A matching run on this store.
    func matchingRun(
        budget: MatchingBudget = testMatchingBudget, batchSize: Int = MatchingLimits.batchSize,
        hooks: MatchingRun.Hooks = .init()
    ) -> MatchingRun {
        MatchingRun(container: container, budget: budget, batchSize: batchSize, hooks: hooks)
    }
}

/// A hook that runs `edit` once, at the first time `matches` holds for its argument.
func once<Kind: Sendable>(
    _ matches: @escaping @Sendable (Kind) -> Bool, _ edit: @escaping @Sendable () throws -> Void
) -> @Sendable (Kind) throws -> Void {
    let done = Mutex(false)
    return { kind in
        guard matches(kind) else { return }
        let first = done.withLock { done in
            defer { done = true }
            return !done
        }
        if first { try edit() }
    }
}
