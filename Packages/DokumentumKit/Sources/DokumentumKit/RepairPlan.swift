import Foundation

/// A reference a repair can change. The associated value is the `instanceID` of the record holding it.
public enum RepairReference: Hashable, Sendable {
    case correspondent(document: UUID)
    case documentType(document: UUID)
    /// One of a document's tags: `from` goes and `to` comes in the same transaction (I3).
    case tag(document: UUID)
    case parent(tag: UUID)
}

/// One change to the store. Records are named by `instanceID`, never by `id`.
///
/// **There is no delete operation, so a plan cannot express one (I1).**
public enum RepairOperation: Hashable, Sendable {
    /// Replaces a reference to the tombstone `from` by the live record `to`.
    case repoint(reference: RepairReference, from: UUID, to: UUID)
    /// `into` takes the loser's documents (for tags also its children, unconditionally), and the loser
    /// becomes a tombstone.
    case mergeMetadata(kind: MetadataKind, loser: UUID, into: UUID)
    /// Breaks a cycle. The only operation that may set a reference to `nil` (the I3 exception).
    case makeRoot(tag: UUID, expectedParent: UUID)
    /// Links a blob to a document that has no blob of that kind.
    case relink(blob: UUID, to: UUID)
    /// Clears a tombstone's state. The only operation that does (I4).
    case revive(tombstone: UUID)
}

/// An ordered list of operations.
public struct RepairPlan: Hashable, Sendable {
    public var operations: [RepairOperation]

    public init(_ operations: [RepairOperation] = []) {
        self.operations = operations
    }

    public var isEmpty: Bool { operations.isEmpty }
}

/// What applying a plan did.
public struct RepairApplication: Hashable, Sendable {
    public var snapshot: RepairSnapshot
    public var applied: [RepairOperation]
    /// Operations whose precondition no longer held; the next run plans them again.
    public var skipped: [RepairOperation]
}

extension RepairPlan {
    /// Applies the operations in order to a copy of `snapshot`. Used to simulate later passes while
    /// planning, and by tests in place of the store.
    ///
    /// This also defines the precondition of each operation (I6), which the SwiftData layer re-checks
    /// before its save: an operation applies only if the reference it changes still holds the planned
    /// value, source and target are present and as live as planned, a merge's two records still have
    /// the same name (and for tags the same parent), and a relink's blob is unlinked and its document
    /// has no blob of that kind. Otherwise it is skipped.
    public func apply(to snapshot: RepairSnapshot, now: Date) -> RepairApplication {
        var workspace = RepairWorkspace(state: snapshot, now: now)
        var applied: [RepairOperation] = []
        var skipped: [RepairOperation] = []
        for operation in operations {
            if workspace.apply(operation) {
                applied.append(operation)
            } else {
                skipped.append(operation)
            }
        }
        return RepairApplication(snapshot: workspace.state, applied: applied, skipped: skipped)
    }
}

private struct RepairWorkspace {
    var state: RepairSnapshot
    let now: Date
    private let documentIndex: [UUID: Int]
    private let metadataIndex: [UUID: Int]
    private let blobIndex: [UUID: Int]

    init(state: RepairSnapshot, now: Date) {
        self.state = state
        self.now = now
        documentIndex = Self.index(state.documents)
        metadataIndex = Self.index(state.metadata)
        blobIndex = Self.index(state.blobs)
    }

    private static func index<T: KeeperOrdered>(_ records: [T]) -> [UUID: Int] {
        Dictionary(records.enumerated().map { ($1.instanceID, $0) }, uniquingKeysWith: { first, _ in first })
    }

    mutating func apply(_ operation: RepairOperation) -> Bool {
        switch operation {
        case .repoint(let reference, let from, let to):
            repoint(reference, from: from, to: to)
        case .mergeMetadata(let kind, let loser, let keeper):
            merge(kind, loser: loser, into: keeper)
        case .makeRoot(let tag, let expectedParent):
            makeRoot(tag, expectedParent: expectedParent)
        case .relink(let blob, let document):
            relink(blob, to: document)
        case .revive(let tombstone):
            revive(tombstone)
        }
    }

    private mutating func repoint(_ reference: RepairReference, from: UUID, to: UUID) -> Bool {
        guard let source = metadataIndex[from].map({ state.metadata[$0] }), !source.isLive,
            let target = metadataIndex[to].map({ state.metadata[$0] }), target.isLive,
            source.kind == target.kind
        else { return false }
        switch reference {
        case .correspondent(let document):
            guard target.kind == .correspondent, let index = documentIndex[document],
                state.documents[index].correspondent == from
            else { return false }
            state.documents[index].correspondent = to
            state.documents[index].modifiedAt = now
        case .documentType(let document):
            guard target.kind == .documentType, let index = documentIndex[document],
                state.documents[index].documentType == from
            else { return false }
            state.documents[index].documentType = to
            state.documents[index].modifiedAt = now
        case .tag(let document):
            guard target.kind == .tag, let index = documentIndex[document],
                state.documents[index].tags.contains(from)
            else { return false }
            state.documents[index].tags.remove(from)
            state.documents[index].tags.insert(to)
            state.documents[index].modifiedAt = now
        case .parent(let tag):
            guard target.kind == .tag, let index = metadataIndex[tag],
                state.metadata[index].kind == .tag, state.metadata[index].parentInstanceID == from
            else { return false }
            state.metadata[index].parentInstanceID = to
        }
        return true
    }

    private mutating func merge(_ kind: MetadataKind, loser: UUID, into keeper: UUID) -> Bool {
        guard loser != keeper, let loserIndex = metadataIndex[loser], let keeperIndex = metadataIndex[keeper]
        else { return false }
        let (source, target) = (state.metadata[loserIndex], state.metadata[keeperIndex])
        guard source.kind == kind, target.kind == kind, source.isLive, target.isLive,
            MetadataName.normalized(source.name) == MetadataName.normalized(target.name),
            kind != .tag || source.parentInstanceID == target.parentInstanceID
        else { return false }
        for index in state.documents.indices {
            moveDocument(at: index, kind: kind, from: loser, to: keeper)
        }
        if kind == .tag {
            // Unconditional, tombstones and the keeper included: pass 3 breaks a cycle this closes, and
            // nothing keeps pointing at the new tombstone, so the next run has nothing to re-point.
            for index in state.metadata.indices where state.metadata[index].parentInstanceID == loser {
                state.metadata[index].parentInstanceID = keeper
            }
        }
        state.metadata[loserIndex].mergedIntoID = target.id
        state.metadata[loserIndex].mergedAt = now
        return true
    }

    private mutating func moveDocument(at index: Int, kind: MetadataKind, from loser: UUID, to keeper: UUID) {
        switch kind {
        case .correspondent:
            guard state.documents[index].correspondent == loser else { return }
            state.documents[index].correspondent = keeper
        case .documentType:
            guard state.documents[index].documentType == loser else { return }
            state.documents[index].documentType = keeper
        case .tag:
            guard state.documents[index].tags.remove(loser) != nil else { return }
            state.documents[index].tags.insert(keeper)
        }
        state.documents[index].modifiedAt = now
    }

    private mutating func makeRoot(_ tag: UUID, expectedParent: UUID) -> Bool {
        guard let index = metadataIndex[tag], state.metadata[index].kind == .tag, state.metadata[index].isLive,
            state.metadata[index].parentInstanceID == expectedParent
        else { return false }
        state.metadata[index].parentInstanceID = nil
        return true
    }

    private mutating func relink(_ blob: UUID, to document: UUID) -> Bool {
        guard let index = blobIndex[blob], let documentIndex = documentIndex[document],
            state.blobs[index].linkedDocumentInstanceID == nil,
            state.blobs[index].documentID == state.documents[documentIndex].id
        else { return false }
        let kind = state.blobs[index].kind
        guard !state.blobs.contains(where: { $0.kind == kind && $0.linkedDocumentInstanceID == document })
        else { return false }
        state.blobs[index].linkedDocumentInstanceID = document
        return true
    }

    private mutating func revive(_ tombstone: UUID) -> Bool {
        guard let index = metadataIndex[tombstone], !state.metadata[index].isLive else { return false }
        state.metadata[index].mergedIntoID = nil
        state.metadata[index].mergedAt = nil
        return true
    }
}
