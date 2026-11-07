import DokumentumCore
import DokumentumTestSupport
import Foundation
import SwiftData
import Synchronization

extension TestSupport {
    /// A fresh in-memory archive with the app's schema and migration plan, never synced. It lives until the
    /// end of the test run (`ContainerKeeper`).
    @discardableResult
    public static func makeContainer() throws -> ModelContainer {
        try keepAlive(ArchiveStore.open(ArchiveStore.configuration(for: .inMemory(seed: false))))
    }

    /// A fresh archive in a new temporary folder, never synced. For tests that need a file: store change
    /// notifications (in-memory stores all report `/dev/null` as their URL), SQL evidence, reopening.
    public static func makeContainerOnDisk() throws -> ModelContainer {
        try makeContainerOnDisk(at: makeTemporaryDirectory().appending(path: "Test.store"))
    }

    /// The archive in the store file at `url` (created if missing), never synced. For tests that open the
    /// same file again. It lives until the end of the test run (`ContainerKeeper`).
    public static func makeContainerOnDisk(at url: URL) throws -> ModelContainer {
        try keepAlive(ArchiveStore.open(ArchiveStore.configuration(for: .local, at: url)))
    }

    /// Keeps a container that a test got from elsewhere (`ArchiveStore.makeContainer`) alive until the end
    /// of the test run, like the ones from `makeContainer()`: an autosave or a task that outlives its test
    /// never finds its container gone.
    @discardableResult
    public static func keepAlive(_ container: ModelContainer) -> ModelContainer {
        ContainerKeeper.shared.keep(container)
        return container
    }

    /// A new, empty temporary folder of its own.
    public static func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(
            path: "DokumentumTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

/// Holds every test container until the process ends.
public final class ContainerKeeper: Sendable {
    public static let shared = ContainerKeeper()

    private let containers = Mutex<[ModelContainer]>([])

    public func keep(_ container: ModelContainer) {
        containers.withLock { $0.append(container) }
    }
}
