#if DEBUG
    import DokumentumCore
    import DokumentumKit
    import Foundation
    #if os(macOS)
        import AppKit
    #else
        import UIKit
    #endif

    /// `-UITestImportLetter <id>` (Debug builds only; #11, part 2, N10): once the first library window appears, the
    /// app imports the `SyntheticLetters` entry `<id>` as a text PDF (`SyntheticPDF.makeLetter`) through the window's
    /// `ImportController`, as the files picker would. The UI smoke then waits for the detected correspondent and
    /// date in the document's info.
    ///
    /// **Honoured only with `-UITestLocalStore`**, never into the archive: detection runs in the processing queue,
    /// and the queue runs only on stores on disk (`DokumentumApp`), so the in-memory stores of
    /// `-UITestImportSynthetic` would never detect anything. The letter is written to a folder of the app's
    /// temporary directory, emptied at launch and removed when the app terminates.
    enum UITestImportLetter {
        static let argument = "-UITestImportLetter"

        /// The letter of this launch, or `nil` without the argument, without `-UITestLocalStore`, on another store
        /// or with an unknown id.
        static func letter(arguments: [String], launchStore: LaunchStore) -> SyntheticLetter? {
            guard launchStore.choice.isOnDisk, UITestLocalStore.folder(arguments: arguments) != nil,
                let index = arguments.firstIndex(of: argument), arguments.indices.contains(index + 1)
            else { return nil }
            return SyntheticLetters.letter(arguments[index + 1])
        }

        /// `<tmp>/DokumentumUITestLetter`, a fixed name in the app's own temporary directory.
        static var folderURL: URL {
            FileManager.default.temporaryDirectory.appending(
                path: "DokumentumUITestLetter", directoryHint: .isDirectory)
        }

        @MainActor private static var hasRun = false

        /// Writes and imports the letter, once per launch, however many windows appear.
        @MainActor
        static func runOnce(_ controller: ImportController, launchStore: LaunchStore) async {
            guard !hasRun, let letter = letter(arguments: ProcessInfo.processInfo.arguments, launchStore: launchStore)
            else { return }
            hasRun = true
            let url: URL
            do {
                url = try writeFile(letter)
            } catch {
                Log.importing.error("Synthetic letter not written: \(Log.code(of: error), privacy: .public)")
                return
            }
            removeFolderWhenTerminating()
            await controller.importFiles([url])
        }

        /// The folder, emptied, with the letter as `<id>.pdf`; its URL.
        static func writeFile(_ letter: SyntheticLetter, into folder: URL = folderURL) throws -> URL {
            let manager = FileManager.default
            if manager.fileExists(atPath: folder.path(percentEncoded: false)) { try manager.removeItem(at: folder) }
            try manager.createDirectory(at: folder, withIntermediateDirectories: true)
            let url = folder.appending(path: "\(letter.id).pdf")
            try SyntheticPDF.makeLetter(letter).write(to: url)
            return url
        }

        @MainActor
        private static func removeFolderWhenTerminating() {
            #if os(macOS)
                let name = NSApplication.willTerminateNotification
            #else
                let name = UIApplication.willTerminateNotification
            #endif
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
                try? FileManager.default.removeItem(at: folderURL)
            }
        }
    }
#endif
