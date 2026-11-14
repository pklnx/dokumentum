import DokumentumKit
import Foundation

/// Turns the store's light values into the library's (plan of #3, part 2). Pure and read only: it never
/// writes, and re-pointing references stays the repair's job (#30, pass 1).
///
/// **References to tombstones.** A document can still point at a correspondent, type or tag that the repair
/// merged away: before pass 1 has run, or while the chain's end has not arrived. The mapping follows the
/// `mergedIntoID` chain the way pass 1 does (`MetadataChains`: a visited set, and among records sharing the
/// target `id` the live one that comes first in `keeperOrder`):
/// - the chain ends at a live record: the row shows that record's name and matches its sidebar entry;
/// - it ends nowhere (a missing end or a loop): the row shows the tombstone's own name and matches no sidebar
///   entry, so the document stays under Inbox and All Documents only.
public enum LibraryMapping {
    /// The library for `documents` (trashed ones included) and every metadata record, tombstones included.
    /// The sidebar lists only the live records.
    public static func snapshot(documents: [DocumentSummary], metadata: [MetadataSnapshot]) -> LibrarySnapshot {
        let resolver = Resolver(metadata)
        var unlistedTagNames: [UUID: String] = [:]
        let rows = documents.map { summary in
            var tagIDs: Set<UUID> = []
            for tag in summary.tagInstanceIDs {
                switch resolver.resolve(tag) {
                case .live(let live): tagIDs.insert(live.instanceID)
                case .unresolved(let tombstone):
                    tagIDs.insert(tag)
                    unlistedTagNames[tag] = tombstone.name
                case .unknown: tagIDs.insert(tag)
                }
            }
            return LibraryDocument(
                instanceID: summary.instanceID, title: summary.title, documentDate: summary.documentDate,
                createdAt: summary.createdAt, isInbox: summary.isInbox, deletedAt: summary.deletedAt,
                correspondent: summary.correspondent.map(resolver.reference(for:)),
                documentType: summary.documentType.map(resolver.reference(for:)), tagIDs: tagIDs, fileState: .unknown,
                processingState: summary.processingState, deadline: summary.deadline,
                dismissedSuggestionDay: summary.dismissedSuggestionDay)
        }
        let live = metadata.filter(\.isLive)
        let tags = live.filter { $0.kind == .tag }.map { tag in
            TagRecord(
                instanceID: tag.instanceID, parentInstanceID: tag.parentInstanceID.map(resolver.liveInstanceID(for:)),
                name: tag.name)
        }
        return LibrarySnapshot(
            documents: rows, tags: tags,
            correspondents: live.filter { $0.kind == .correspondent }.map(reference(of:)),
            documentTypes: live.filter { $0.kind == .documentType }.map(reference(of:)),
            unlistedTagNames: unlistedTagNames)
    }

    private static func reference(of record: MetadataSnapshot) -> LibraryDocument.Reference {
        LibraryDocument.Reference(instanceID: record.instanceID, name: record.name)
    }

    /// Each chain is followed once per mapping, however many documents point at it.
    private final class Resolver {
        enum Resolution {
            /// Live itself, or a tombstone whose chain ends at this live record.
            case live(MetadataSnapshot)
            /// A tombstone whose chain ends nowhere.
            case unresolved(tombstone: MetadataSnapshot)
            /// Not among the records read.
            case unknown
        }

        private let records: [UUID: MetadataSnapshot]
        private let chains: MetadataChains
        private var resolved: [UUID: Resolution] = [:]

        init(_ metadata: [MetadataSnapshot]) {
            records = Dictionary(metadata.map { ($0.instanceID, $0) }, uniquingKeysWith: { first, _ in first })
            chains = MetadataChains(RepairSnapshot(metadata: metadata))
        }

        func resolve(_ instanceID: UUID) -> Resolution {
            if let known = resolved[instanceID] { return known }
            let resolution: Resolution
            if let record = records[instanceID] {
                if record.isLive {
                    resolution = .live(record)
                } else if case .live(let end)? = chains.end(of: instanceID), let live = records[end] {
                    resolution = .live(live)
                } else {
                    resolution = .unresolved(tombstone: record)
                }
            } else {
                resolution = .unknown
            }
            resolved[instanceID] = resolution
            return resolution
        }

        /// The live end's reference, or the reference as stored.
        func reference(for stored: MetadataReference) -> LibraryDocument.Reference {
            if case .live(let live) = resolve(stored.instanceID) {
                return LibraryDocument.Reference(instanceID: live.instanceID, name: live.name)
            }
            return LibraryDocument.Reference(instanceID: stored.instanceID, name: stored.name)
        }

        /// The live end's `instanceID`, or `instanceID` itself. A tag parent that ends nowhere is not in the
        /// tree, so `TagTree` shows the tag as a root.
        func liveInstanceID(for instanceID: UUID) -> UUID {
            if case .live(let live) = resolve(instanceID) { return live.instanceID }
            return instanceID
        }
    }
}
