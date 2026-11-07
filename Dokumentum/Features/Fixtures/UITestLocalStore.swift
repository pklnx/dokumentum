#if DEBUG
    import Foundation

    /// `-UITestLocalStore <name>` (Debug builds only): a local store on disk in a new folder of the app's
    /// temporary directory, never at the archive's path. For UI tests and screenshots of a store on disk (the
    /// Mac's "Sync off: this build has no iCloud access"). The folder is emptied at each such launch.
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
    }
#endif
