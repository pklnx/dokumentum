import CoreTransferable
import Foundation
import UniformTypeIdentifiers

/// A PDF or an image dropped onto the library window (Mac). The system gives the file only for the duration of the
/// transfer, so it is copied into a folder of its own in the temporary directory, under its own name (the
/// name becomes the title); `remove()` deletes that folder after the import. Ported from the predecessor's
/// `ImportedFile` (pklnx/document-archive `ec5c71d`).
struct ImportedFile: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .pdf) { try ImportedFile(copying: $0.file) }
        FileRepresentation(importedContentType: .image) { try ImportedFile(copying: $0.file) }
    }

    /// `<tmp>/DroppedFiles`; each drop gets a folder `<UUID>` in it.
    static var temporaryFolder: URL { FileManager.default.temporaryDirectory.appending(path: "DroppedFiles") }

    /// Copies `file` into a new folder of its own, keeping the file name.
    init(copying file: URL, into folder: URL = ImportedFile.temporaryFolder) throws {
        let accessing = file.startAccessingSecurityScopedResource()
        defer { if accessing { file.stopAccessingSecurityScopedResource() } }
        let own = folder.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: own, withIntermediateDirectories: true)
        let copy = own.appending(path: file.lastPathComponent)
        try FileManager.default.copyItem(at: file, to: copy)
        url = copy
    }

    /// Removes the copy's own folder, and nothing else.
    func remove() {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }
}
