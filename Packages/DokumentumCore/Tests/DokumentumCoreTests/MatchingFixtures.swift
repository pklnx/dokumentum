import DokumentumKit
import Foundation
import SwiftData
import Synchronization
import Testing

@testable import DokumentumCore

// The matching tests' tools (#10, part 1b): records with rules, links set by another context, the matching fields
// of a document. The store's saves are counted by `SaveCounter` (`DocumentImporterTests`).

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
        budget: MatchingBudget = .production, batchSize: Int = MatchingLimits.batchSize,
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
