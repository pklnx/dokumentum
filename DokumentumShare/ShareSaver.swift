import DokumentumKit
import Foundation
import UniformTypeIdentifiers

/// Writes shared attachments into the share queue. Only PDFs and images are taken (the activation rule offers
/// the extension for nothing else); other attachments of the same share are left out.
///
/// For each attachment, in this order (plan review N8):
/// 1. `loadFileRepresentation`: a file the system lends for the duration of the call, copied into the queue
///    inside the call. The bytes never pass through memory.
/// 2. If that fails, `loadDataRepresentation` for the same type, which most providers coerce to.
/// 3. Otherwise (an attachment that offers only an image object) it is not written: decoding an image here could
///    run the extension out of memory. The sheet then shows its error.
enum ShareSaver {
    /// The queue in the app group; `nil` without the group (no entitlement), and then nothing can be saved.
    static func appQueue() -> ShareQueue? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: ShareQueue.appGroupIdentifier)
            .map(ShareQueue.init(groupContainer:))
    }

    /// Saves every PDF and image attachment, one after another, in their order.
    /// - Returns: how many of them could not be saved.
    static func save(_ providers: [NSItemProvider], to queue: ShareQueue?) async -> Int {
        var notSaved = 0
        for provider in providers {
            guard let type = type(of: provider) else { continue }
            guard let queue else {
                notSaved += 1
                continue
            }
            let name = provider.suggestedName
            if await saveFile(provider, as: type, name: name, to: queue) { continue }
            if await saveData(provider, as: type, name: name, to: queue) { continue }
            notSaved += 1
        }
        return notSaved
    }

    /// The attachment's own PDF type, else its own image type (such as `public.jpeg`); `nil` for anything else.
    static func type(of provider: NSItemProvider) -> UTType? {
        let types = provider.registeredTypeIdentifiers.compactMap(UTType.init)
        return types.first { $0.conforms(to: .pdf) } ?? types.first { $0.conforms(to: .image) }
    }

    /// The name the item gets: the suggested one, else the lent file's, with the type's extension when it has
    /// none of that type (so the title keeps a part after a dot). The queue treats it as data, never as a path.
    static func fileName(suggested: String?, fileURL: URL?, type: UTType) -> String {
        let base = suggested.flatMap { $0.isEmpty ? nil : $0 } ?? fileURL?.lastPathComponent ?? ""
        let pathExtension = (base as NSString).pathExtension
        if !pathExtension.isEmpty, UTType(filenameExtension: pathExtension)?.conforms(to: type) == true {
            return base
        }
        guard let preferred = type.preferredFilenameExtension else { return base }
        return "\(base).\(preferred)"
    }

    private static func saveFile(_ provider: NSItemProvider, as type: UTType, name: String?, to queue: ShareQueue)
        async -> Bool
    {
        await withCheckedContinuation { continuation in
            _ = provider.loadFileRepresentation(for: type, openInPlace: false) { url, _, _ in
                // The file exists only until this handler returns, so it is copied here.
                guard let url else {
                    continuation.resume(returning: false)
                    return
                }
                let saved = try? queue.add(
                    copyingFileAt: url, originalFileName: fileName(suggested: name, fileURL: url, type: type),
                    typeIdentifier: type.identifier)
                continuation.resume(returning: saved != nil)
            }
        }
    }

    private static func saveData(_ provider: NSItemProvider, as type: UTType, name: String?, to queue: ShareQueue)
        async -> Bool
    {
        await withCheckedContinuation { continuation in
            _ = provider.loadDataRepresentation(for: type) { data, _ in
                guard let data, !data.isEmpty else {
                    continuation.resume(returning: false)
                    return
                }
                let saved = try? queue.add(
                    data: data, originalFileName: fileName(suggested: name, fileURL: nil, type: type),
                    typeIdentifier: type.identifier)
                continuation.resume(returning: saved != nil)
            }
        }
    }
}
