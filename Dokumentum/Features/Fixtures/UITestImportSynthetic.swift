#if DEBUG
    import DokumentumCore
    import Foundation
    #if os(macOS)
        import AppKit
    #else
        import UIKit
    #endif

    /// `-UITestImportSynthetic YES` (Debug builds only, plan of #4, parts 2 and 3, N4): once the first library
    /// window appears, the app writes generated files into a folder of its temporary directory and imports
    /// them through the window's `ImportController`, as the files picker would: two different PDFs
    /// (`SyntheticPDF`), a portrait photo stored with EXIF orientation 6 (`SyntheticImage`), then the first
    /// PDF's bytes under another name. So a UI test imports without driving a system
    /// picker, and no folder is shared between the test runner and the app.
    ///
    /// Honoured only with an in-memory store (`-UITestEmptyStore`, `-UITestSeed`), never into an archive on
    /// disk. The folder is emptied at launch and removed when the app terminates; the files picker opens in
    /// it, so its screenshots show only these files.
    enum UITestImportSynthetic {
        static let argument = "-UITestImportSynthetic"

        /// What a generated file holds.
        enum Content {
            /// A PDF with these pages.
            case pdf([[String]])
            /// A portrait photo with these lines.
            case portraitPhoto([String])
            /// The first file's bytes again.
            case copyOfFirst
        }

        /// The files in import order.
        static let files: [(name: String, content: Content)] = [
            ("Rechnung Stadtwerke.pdf", .pdf([["Stadtwerke Musterstadt", "Rechnung Strom", "Betrag 84,20 EUR"]])),
            ("Kontoauszug Oktober.pdf", .pdf([["Musterbank", "Kontoauszug Oktober"], ["Seite 2"]])),
            ("Kassenbon Bäckerei.jpg", .portraitPhoto(["Bäckerei Muster", "Kassenbon", "Summe 4,80 EUR"])),
            ("Rechnung Kopie.pdf", .copyOfFirst),
        ]

        static func isRequested(arguments: [String], launchStore: LaunchStore) -> Bool {
            !launchStore.choice.isOnDisk && arguments.contains(argument)
        }

        /// `<tmp>/DokumentumUITestImport`, a fixed name in the app's own temporary directory.
        static var folderURL: URL {
            FileManager.default.temporaryDirectory.appending(
                path: "DokumentumUITestImport", directoryHint: .isDirectory)
        }

        /// The files picker's default folder for this launch; `nil` (the system's choice) without the argument.
        static func folder(for launchStore: LaunchStore) -> URL? {
            isRequested(arguments: ProcessInfo.processInfo.arguments, launchStore: launchStore) ? folderURL : nil
        }

        @MainActor private static var hasRun = false

        /// Writes and imports the files, once per launch, however many windows appear.
        @MainActor
        static func runOnce(_ controller: ImportController, launchStore: LaunchStore) async {
            guard !hasRun, isRequested(arguments: ProcessInfo.processInfo.arguments, launchStore: launchStore)
            else { return }
            hasRun = true
            let urls: [URL]
            do {
                urls = try writeFiles()
            } catch {
                Log.importing.error("Synthetic files not written: \(Log.code(of: error), privacy: .public)")
                return
            }
            removeFolderWhenTerminating()
            await controller.importFiles(urls)
        }

        /// The folder, emptied, with the generated files; their URLs in import order.
        static func writeFiles(into folder: URL = folderURL) throws -> [URL] {
            let manager = FileManager.default
            if manager.fileExists(atPath: folder.path(percentEncoded: false)) { try manager.removeItem(at: folder) }
            try manager.createDirectory(at: folder, withIntermediateDirectories: true)
            var first: Data?
            var urls: [URL] = []
            for file in files {
                let data =
                    switch file.content {
                    case .pdf(let pages): SyntheticPDF.make(pages: pages)
                    case .portraitPhoto(let lines): SyntheticImage.makePortraitPhoto(lines: lines)
                    case .copyOfFirst: first ?? Data()
                    }
                if first == nil { first = data }
                let url = folder.appending(path: file.name)
                try data.write(to: url)
                urls.append(url)
            }
            return urls
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
