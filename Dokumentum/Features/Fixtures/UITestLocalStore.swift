#if DEBUG
    import Foundation
    #if os(macOS)
        import AppKit
    #else
        import UIKit
    #endif

    /// `-UITestLocalStore <name>` (Debug builds only): a local store on disk in a new folder of the app's
    /// temporary directory, never at the archive's path. For UI tests and screenshots of a store on disk (the
    /// Mac's "Sync off: this build has no iCloud access"). The folder is emptied at each such launch and
    /// removed when the app terminates (`removeFolder`).
    enum UITestLocalStore {
        static let argument = "-UITestLocalStore"

        /// The store's folder for `arguments`; `nil` without the argument or with a name that is not plain
        /// letters, digits and hyphens, so it can never name a path outside the temporary directory.
        static func folder(arguments: [String], temporaryDirectory: URL = FileManager.default.temporaryDirectory)
            -> URL?
        {
            guard let index = arguments.firstIndex(of: argument), index + 1 < arguments.count else { return nil }
            let name = arguments[index + 1]
            guard !name.isEmpty, name.count <= 64,
                name.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || $0 == "-" }),
                name.allSatisfy(\.isASCII)
            else { return nil }
            return temporaryDirectory.appending(path: "DokumentumUITest-\(name)", directoryHint: .isDirectory)
        }

        /// Removes the store's folder for `arguments`, the one `folder(arguments:)` builds from the validated
        /// name, and nothing else; does nothing without the argument or with an invalid name.
        /// - Returns: whether there was a folder to remove.
        ///
        /// The app calls it at launch and when it terminates (`removeFolderWhenTerminating`).
        @discardableResult
        static func removeFolder(
            arguments: [String], temporaryDirectory: URL = FileManager.default.temporaryDirectory,
            fileManager: FileManager = .default
        ) -> Bool {
            guard let folder = folder(arguments: arguments, temporaryDirectory: temporaryDirectory),
                fileManager.fileExists(atPath: folder.path(percentEncoded: false))
            else { return false }
            do {
                try fileManager.removeItem(at: folder)
                return true
            } catch {
                return false
            }
        }

        /// Removes the store's folder when the app terminates normally, as `XCUIApplication.terminate()` ends
        /// a UI test's launch. The folder's path is fixed now, from the launch's own arguments.
        @MainActor
        static func removeFolderWhenTerminating(arguments: [String]) {
            guard folder(arguments: arguments) != nil else { return }
            #if os(macOS)
                let name = NSApplication.willTerminateNotification
            #else
                let name = UIApplication.willTerminateNotification
            #endif
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
                removeFolder(arguments: arguments)
            }
        }
    }
#endif
