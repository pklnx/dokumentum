import DokumentumKit
import Foundation
import UniformTypeIdentifiers

/// Writes shared attachments into the share queue. Only PDFs and images are taken (the activation rule offers
/// the extension for nothing else); other attachments of the same share are left out.
///
/// For each attachment, in this order (plan review N8), held by `ShareQueue.saveAttachment` (tested in Kit, #104);
/// `save` reaches `saveData` only through it:
/// 1. `loadFileRepresentation`: a file the system lends for the duration of the call, copied into the queue
///    inside the call. The file is never held in memory: `ShareQueue` copies it through one 1 MiB buffer. Only a
///    regular file is copied (review of #85).
/// 2. Only if no file was lent or the lent file could not be opened (a file that is gone, `EACCES`),
///    `loadDataRepresentation` for the same type, which most providers coerce to
///    (`ShareQueue.fallsBackToData(afterFileError:)`). **Never when the lent file was refused** as `NotARegularFile`
///    (a symbolic link, a folder, a FIFO, a socket or a device), so the extension never reads a link's target (#87,
///    the maintainer's decision on P1): Files lends a link as a link, and the data would be the target's bytes.
///    **Never after `CopyFailed`**, a failure once the lent file was opened (reading it, or writing the queue: a
///    full device, `EIO`; #104, the maintainer's decision P1 = A): the data would go to the same volume, and loading
///    it holds the whole attachment in memory. In both cases the attachment is not saved and the sheet shows its
///    error.
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
            guard let type = shareType(of: provider) else { continue }
            guard let queue else {
                notSaved += 1
                continue
            }
            let name = provider.suggestedName
            let saved = await ShareQueue.saveAttachment(
                savingFile: { await saveFile(provider, as: type, name: name, to: queue) },
                savingData: { await saveData(provider, as: type, name: name, to: queue) })
            if !saved { notSaved += 1 }
        }
        return notSaved
    }

    /// The attachment's own PDF type, else its own image type (such as `public.jpeg`); `nil` for anything else.
    static func shareType(of provider: NSItemProvider) -> UTType? {
        let types = provider.registeredTypeIdentifiers.compactMap(UTType.init)
        return types.first { $0.conforms(to: .pdf) } ?? types.first { $0.conforms(to: .image) }
    }

    /// The name the item gets: `ShareQueue.itemFileName`'s rule (tested in Kit), with the type information only
    /// this side has. The queue treats the name as data, never as a path.
    static func fileName(suggested: String?, fileURL: URL?, type: UTType) -> String {
        ShareQueue.itemFileName(
            suggested: suggested, lentFileName: fileURL?.lastPathComponent,
            preferredExtension: type.preferredFilenameExtension, date: Date()
        ) { pathExtension in
            guard let type = UTType(filenameExtension: pathExtension) else { return false }
            return type.conforms(to: .pdf) || type.conforms(to: .image)
        }
    }

    private static func saveFile(_ provider: NSItemProvider, as type: UTType, name: String?, to queue: ShareQueue)
        async -> ShareQueue.FileStep
    {
        await withCheckedContinuation { continuation in
            _ = provider.loadFileRepresentation(for: type, openInPlace: false) { url, _, _ in
                // The file exists only until this handler returns, so it is copied here.
                guard let url else {
                    continuation.resume(returning: .notSaved(nil))
                    return
                }
                do {
                    try queue.add(
                        copyingFileAt: url, originalFileName: fileName(suggested: name, fileURL: url, type: type),
                        typeIdentifier: type.identifier)
                    continuation.resume(returning: .saved)
                } catch {
                    continuation.resume(returning: .notSaved(error))
                }
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
