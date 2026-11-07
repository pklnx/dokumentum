import DokumentumKit
import Foundation
import SwiftData

/// The library on the store (plan of #3, part 2): the app's `LibrarySource` from part 2 on. It reads the
/// documents only through `DocumentListQuery` (no text, no PDF, no thumbnail) and the metadata through light
/// fetches, and maps them with `LibraryMapping`. The PDF of the open document comes from `DocumentFileLoader`,
/// off the main actor.
///
/// **Changes:** `changes` fires after any context of this container saves (`ModelContext.didSave`). Remote
/// changes and CloudKit imports are not seen yet: #30's `StoreChangeObserver` adds them (part 5 of #3).
public final class StoreLibrarySource: Sendable {
    public let container: ModelContainer
    /// Fires after a save; a burst of saves leaves one pending event.
    public let changes: AsyncStream<Void>
    private let loader: DocumentFileLoader
    private let observation: SaveObservation

    public init(container: ModelContainer) {
        self.container = container
        loader = DocumentFileLoader(container: container)
        let (changes, continuation) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        self.changes = changes
        let observation = SaveObservation(container: container) { continuation.yield() }
        self.observation = observation
        continuation.onTermination = { _ in observation.cancel() }
    }

    /// Everything the sidebar and the list show, read from the main context.
    @MainActor
    public func snapshot() -> LibrarySnapshot {
        do {
            return try Self.read(in: container.mainContext)
        } catch {
            Log.store.error("Could not read the library: \(Log.code(of: error), privacy: .public)")
            return .empty
        }
    }

    /// The PDF of one document, off the main actor.
    public func loadPDF(instanceID: UUID) async -> PDFLoadState {
        await loader.load(instanceID: instanceID)
    }

    /// The library in `context`: the list query's rows (trashed ones included) and every tag, correspondent
    /// and type, tombstones included, so references to tombstones can be followed (`LibraryMapping`).
    public static func read(in context: ModelContext) throws -> LibrarySnapshot {
        let documents =
            try DocumentListQuery.fetch(.all, in: context) + DocumentListQuery.fetch(.trash, in: context)
        return LibraryMapping.snapshot(documents: documents, metadata: try metadata(in: context))
    }

    /// Every tag, correspondent and document type as the repair sees them, without their documents.
    public static func metadata(in context: ModelContext) throws -> [MetadataSnapshot] {
        var tags = FetchDescriptor<Tag>()
        tags.relationshipKeyPathsForPrefetching = [\.parent]
        let tagSnapshots = try context.fetch(tags).map { tag in
            MetadataSnapshot(
                kind: .tag, instanceID: tag.instanceID, id: tag.id, createdAt: tag.createdAt, mergedAt: tag.mergedAt,
                name: tag.name, parentInstanceID: tag.parent?.instanceID, mergedIntoID: tag.mergedIntoID)
        }
        let correspondents = try context.fetch(FetchDescriptor<Correspondent>()).map { record in
            MetadataSnapshot(
                kind: .correspondent, instanceID: record.instanceID, id: record.id, createdAt: record.createdAt,
                mergedAt: record.mergedAt, name: record.name, mergedIntoID: record.mergedIntoID)
        }
        let types = try context.fetch(FetchDescriptor<DocumentType>()).map { record in
            MetadataSnapshot(
                kind: .documentType, instanceID: record.instanceID, id: record.id, createdAt: record.createdAt,
                mergedAt: record.mergedAt, name: record.name, mergedIntoID: record.mergedIntoID)
        }
        return tagSnapshots + correspondents + types
    }
}

/// Calls `onSave` after every save of a context of one container, until cancelled or released. `onSave` runs
/// synchronously on the saving thread, inside `save()`.
final class SaveObservation: Sendable {
    private let token: Token

    init(container: ModelContainer, onSave: @escaping @Sendable () -> Void) {
        let container = ObjectIdentifier(container)
        token = Token(
            NotificationCenter.default.addObserver(forName: ModelContext.didSave, object: nil, queue: nil) {
                notification in
                guard let context = notification.object as? ModelContext,
                    ObjectIdentifier(context.container) == container
                else { return }
                onSave()
            })
    }

    func cancel() { token.remove() }

    deinit { token.remove() }

    /// The observer token; removing it twice does nothing.
    private final class Token: @unchecked Sendable {
        // Guarded by `lock`.
        private var observer: (any NSObjectProtocol)?
        private let lock = NSLock()

        init(_ observer: any NSObjectProtocol) { self.observer = observer }

        func remove() {
            let observer = lock.withLock {
                defer { self.observer = nil }
                return self.observer
            }
            if let observer { NotificationCenter.default.removeObserver(observer) }
        }
    }
}
