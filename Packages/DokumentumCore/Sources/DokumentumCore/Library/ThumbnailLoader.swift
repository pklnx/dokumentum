import CoreGraphics
import DokumentumKit
import Foundation
import ImageIO
import SwiftData
import Synchronization

/// Loads the thumbnail of one document for a list row (#6, part 4), off the main actor, the `DocumentFileLoader`
/// pattern: one document by key and its thumbnail, in a context of its own that ends with the load, so the list query
/// never reads a thumbnail (`DocumentListQuerySQLTests`) and no context keeps the images it loaded.
///
/// The image is decoded once, scaled to `pixelSize` on its long side, and kept by `instanceID` (at most
/// `cacheLimit`, the oldest dropped first). Only images are kept: a document whose thumbnail has not arrived is
/// read again on the next load, so a row shows a thumbnail that arrives by sync once the library reads again. A
/// thumbnail never changes once it exists (`Thumbnail`), so a kept image is never stale.
public final class ThumbnailLoader: Sendable {
    /// The long side of a decoded image in pixels: a row's thumbnail is 56 pt high, at 3× on the iPhone.
    public static let pixelSize = 168
    /// How many decoded images are kept: about 80 KB each.
    public static let cacheLimit = 300

    public let container: ModelContainer
    private let cacheLimit: Int
    private let cache = Mutex(Cache())

    private struct Cache {
        var images: [UUID: CGImage] = [:]
        /// Oldest first.
        var order: [UUID] = []
    }

    public init(container: ModelContainer, cacheLimit: Int = ThumbnailLoader.cacheLimit) {
        self.container = container
        self.cacheLimit = cacheLimit
    }

    /// The decoded thumbnail of the document with `instanceID`; `nil` when there is no such document, it has no
    /// thumbnail yet, its data has not arrived, or it does not decode.
    @concurrent
    public func image(for instanceID: UUID) async -> CGImage? {
        if let kept = cache.withLock({ $0.images[instanceID] }) { return kept }
        guard let data = Self.data(for: instanceID, in: container), let image = Self.decode(data) else { return nil }
        cache.withLock { cache in
            if cache.images.updateValue(image, forKey: instanceID) == nil { cache.order.append(instanceID) }
            while cache.order.count > cacheLimit {
                cache.images[cache.order.removeFirst()] = nil
            }
        }
        return image
    }

    /// How many images are kept. For tests.
    var keptCount: Int { cache.withLock { $0.images.count } }

    /// The thumbnail's data, in a context that ends with the read: the document by key, then its linked thumbnail.
    /// Synchronous, so `ThumbnailLoaderSQLTests` can record its SQL on one thread.
    static func data(for instanceID: UUID, in container: ModelContainer) -> Data? {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        // Copies sharing an `instanceID` are read by the one rule, `RowRecords.oldestFirst` (review N4 of #135).
        let descriptor = FetchDescriptor<Document>(predicate: #Predicate { $0.instanceID == instanceID })
        do {
            let document = RowRecords.oldestFirst(try context.fetch(descriptor)).first
            guard let data = document?.thumbnail?.imageData, !data.isEmpty else {
                return nil
            }
            return data
        } catch {
            Log.store.error("Could not fetch a document's thumbnail: \(Log.code(of: error), privacy: .public)")
            return nil
        }
    }

    /// The image in `data`, scaled to `pixelSize` on its long side.
    static func decode(_ data: Data, pixelSize: Int = pixelSize) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: pixelSize,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}
