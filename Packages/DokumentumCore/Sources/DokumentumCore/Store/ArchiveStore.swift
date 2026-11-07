import Foundation
import SwiftData

#if os(macOS)
    import Security
#endif

/// Which store the app opens at launch. Decided before anything touches the disk: test runs never open
/// the archive on disk, never run a migration and never contact iCloud.
public enum StoreChoice: Hashable, Sendable {
    /// Unit tests and UI tests: nothing is read from or written to disk, never synced. `seed` fills it with
    /// sample documents (the seed comes from the app, #3).
    case inMemory(seed: Bool)
    /// The archive on disk, synced through the private CloudKit database.
    case cloudKit
    /// The archive on disk, not synced: a build without the CloudKit entitlement.
    case local

    /// Launch argument for UI tests and screenshots: an in-memory store with sample documents. Honoured in
    /// DEBUG builds only. UI tests pass it as a pair (`-UITestSeed YES`), so the value is not left over as a
    /// file to open.
    public static let uiTestSeedArgument = "-UITestSeed"
    /// Launch argument for UI tests that need an empty archive: an empty in-memory store. Honoured in DEBUG
    /// builds only; passed as a pair like `uiTestSeedArgument`.
    public static let uiTestEmptyStoreArgument = "-UITestEmptyStore"

    public static func decide(isRunningTests: Bool, arguments: [String], cloudKitAvailable: Bool) -> StoreChoice {
        if isRunningTests { return .inMemory(seed: false) }
        if isUITestLaunch(arguments: arguments) {
            return .inMemory(seed: arguments.contains(uiTestSeedArgument))
        }
        return cloudKitAvailable ? .cloudKit : .local
    }

    /// Whether a UI test launched the app with one of the in-memory arguments; always `false` in a Release
    /// build, which ignores them.
    public static func isUITestLaunch(arguments: [String]) -> Bool {
        #if DEBUG
            arguments.contains(uiTestSeedArgument) || arguments.contains(uiTestEmptyStoreArgument)
        #else
            false
        #endif
    }

    /// Whether this choice opens the store file.
    public var isOnDisk: Bool {
        if case .inMemory = self { return false }
        return true
    }
}

/// Creates the SwiftData container for a `StoreChoice`. The one boundary around the store (plan.md,
/// section 3.2): features get the container from here and never build their own configuration.
@MainActor
public enum ArchiveStore {
    /// The CloudKit container; named explicitly, never `.automatic`.
    public nonisolated static let cloudKitContainerIdentifier = "iCloud.space.pklnx.Dokumentum"

    /// The current schema; every container opens through `DokumentumMigrationPlan`.
    public nonisolated static var schema: Schema { Schema(versionedSchema: DokumentumSchemaV1.self) }

    /// `<Application Support>/Dokumentum/Dokumentum.store`, in the app's own container (the sandbox
    /// container on macOS, the data container on iOS), never in the app group: the share extension never
    /// opens the store (plan.md, section 3.4). The CloudKit and the local store use the same file, so
    /// nothing is lost when sync is turned on later. Moving it would be a migration.
    public nonisolated static var storeURL: URL {
        URL.applicationSupportDirectory.appending(path: "Dokumentum/Dokumentum.store")
    }

    /// The second fallback, used only when the store at `storeURL` cannot be opened at all.
    public nonisolated static var fallbackStoreURL: URL {
        URL.applicationSupportDirectory.appending(path: "Dokumentum/Dokumentum-local.store")
    }

    /// The store the app opened at launch; `nil` before. Only `openAtLaunch` sets it, so a test that makes
    /// a container cannot change it.
    public private(set) static var opened: OpenedStore?

    /// The container the app opened at launch; `nil` before. Set with `opened`, only by `openAtLaunch`.
    public private(set) static var current: ModelContainer?

    /// What `makeContainer` actually opened: a CloudKit choice can fall back to local storage.
    public enum OpenedStore: String, Sendable {
        case inMemory = "in memory"
        case sampleData = "in memory with sample data"
        case cloudKit = "CloudKit"
        case local = "local"
        /// The second fallback (`fallbackStoreURL`), after the store at `storeURL` failed.
        case localFallback = "local fallback"
    }

    /// A container and the store it actually opened.
    public struct Opened {
        public let container: ModelContainer
        public let store: OpenedStore
    }

    /// The choice for this launch.
    public static func currentChoice() -> StoreChoice {
        StoreChoice.decide(
            isRunningTests: TestEnvironment.isRunningTests,
            arguments: ProcessInfo.processInfo.arguments,
            cloudKitAvailable: cloudKitAvailable())
    }

    /// Opens the store of the app's launch: the only place that records it in `opened` and `current`. Only
    /// the app's `init` calls it.
    /// - Parameters:
    ///   - url: the store file; only a DEBUG UI test launch passes a temporary one (`-UITestLocalStore`).
    ///   - fallbackURL: the second fallback's file, likewise.
    ///   - seed: fills an `.inMemory(seed: true)` store; unused otherwise.
    public static func openAtLaunch(
        _ choice: StoreChoice, at url: URL = storeURL, fallbackURL: URL = fallbackStoreURL,
        seed: (ModelContext) -> Void = { _ in }
    ) -> ModelContainer {
        let result = makeContainer(for: choice, at: url, fallbackURL: fallbackURL, seed: seed)
        opened = result.store
        current = result.container
        Log.store.notice("Store opened: \(result.store.rawValue, privacy: .public)")
        return result.container
    }

    /// Creates the container for `choice` without changing any global state. A disk store tries CloudKit
    /// first (for `.cloudKit`), then a local store at the same file, then a local store at `fallbackURL`.
    /// - Parameters:
    ///   - url: the store file; tests pass a temporary one.
    ///   - fallbackURL: the second fallback's file; tests pass a temporary one.
    ///   - seed: fills an `.inMemory(seed: true)` store.
    ///   - opener: opens one configuration; `open(_:)` except in tests, which make one step fail without
    ///     CloudKit (a CloudKit configuration is never opened in a test).
    public static func makeContainer(
        for choice: StoreChoice,
        at url: URL = storeURL,
        fallbackURL: URL = fallbackStoreURL,
        seed: (ModelContext) -> Void = { _ in },
        opener: (ModelConfiguration) throws -> ModelContainer = { try ArchiveStore.open($0) }
    ) -> Opened {
        if case .inMemory(let seeded) = choice {
            do {
                let container = try opener(configuration(for: choice, at: url))
                if seeded { seed(container.mainContext) }
                return Opened(container: container, store: seeded ? .sampleData : .inMemory)
            } catch {
                Log.store.fault("Could not create the in-memory store: \(Log.code(of: error), privacy: .public)")
                fatalError("Could not create the in-memory store")
            }
        }
        if choice == .cloudKit {
            do {
                return Opened(container: try opener(configuration(for: .cloudKit, at: url)), store: .cloudKit)
            } catch {
                Log.store.error(
                    """
                    CloudKit store failed, using local storage: \(Log.code(of: error), privacy: .public) \
                    \(error.localizedDescription, privacy: .private)
                    """)
            }
        }
        do {
            return Opened(container: try opener(configuration(for: .local, at: url)), store: .local)
        } catch {
            Log.store.error(
                """
                Local store failed, trying the fallback store: \(Log.code(of: error), privacy: .public) \
                \(error.localizedDescription, privacy: .private)
                """)
        }
        do {
            return Opened(
                container: try opener(configuration(for: .local, at: fallbackURL)), store: .localFallback)
        } catch {
            // The details only into the log, privately: the error contains the store's path, and a fatalError
            // message goes into crash reports as it is.
            Log.store.fault(
                "Could not create the store: \(Log.code(of: error), privacy: .public) \(String(describing: error), privacy: .private)"
            )
            fatalError("Could not create the store")
        }
    }

    /// The configuration for `choice` with its store file at `url`; it opens nothing.
    public nonisolated static func configuration(for choice: StoreChoice, at url: URL = storeURL)
        -> ModelConfiguration
    {
        switch choice {
        case .inMemory:
            ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        case .cloudKit:
            ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .private(cloudKitContainerIdentifier))
        case .local:
            ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)
        }
    }

    /// A container for `configuration` through the migration plan. A store on disk gets its folder first.
    /// In a test run it refuses the live store paths (`isLiveStorePath`) before it touches the disk, so a
    /// bug or a mutation that points a test at them fails instead of writing there.
    public nonisolated static func open(_ configuration: ModelConfiguration) throws -> ModelContainer {
        try refuseLiveStorePath(configuration.url, isRunningTests: TestEnvironment.isRunningTests)
        if !configuration.isStoredInMemoryOnly {
            try FileManager.default.createDirectory(
                at: configuration.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        return try ModelContainer(
            for: schema, migrationPlan: DokumentumMigrationPlan.self, configurations: configuration)
    }

    /// A test run asked to open a store at a live path (`isLiveStorePath`).
    public struct LiveStorePathRefused: Error, Equatable {
        public let url: URL

        public init(url: URL) { self.url = url }
    }

    /// The folder of the live store and its fallback, with their `-wal`, `-shm` and external data files.
    public nonisolated static var liveStoreFolder: URL { storeURL.deletingLastPathComponent() }

    /// Whether `url` lies where the real archive lives: inside `liveStoreFolder`, or in an app group
    /// container (`group.space.pklnx.dokumentum`: `Group Containers` on macOS, `Shared/AppGroup` on iOS).
    /// The group container is matched by its path, without asking the system for it.
    public nonisolated static func isLiveStorePath(_ url: URL) -> Bool {
        let candidates = Set([url.standardizedFileURL, url.standardizedFileURL.resolvingSymlinksInPath()])
        let live = liveStoreFolder.standardizedFileURL
        let folders = Set([live, live.resolvingSymlinksInPath()])
        for candidate in candidates {
            let components = candidate.pathComponents
            for folder in folders where components.starts(with: folder.pathComponents) {
                return true
            }
            let path = candidate.path
            if components.contains("Group Containers") || path.contains("/Shared/AppGroup/")
                || path.localizedCaseInsensitiveContains("group.space.pklnx.dokumentum")
            {
                return true
            }
        }
        return false
    }

    /// Throws `LiveStorePathRefused` when a test run would open a store at a live path; does nothing
    /// outside tests.
    public nonisolated static func refuseLiveStorePath(_ url: URL, isRunningTests: Bool) throws {
        if isRunningTests && isLiveStorePath(url) {
            Log.store.fault("A test tried to open a live store path; refused")
            throw LiveStorePathRefused(url: url)
        }
    }

    /// Whether this build can open a CloudKit store. On macOS that needs the CloudKit entitlement: an
    /// unsigned or ad hoc build (agents' local builds, Xcode Cloud's tests) has none and opens a local
    /// store. iOS has no public API to read an entitlement, and every iOS build carries it (#22).
    public nonisolated static func cloudKitAvailable() -> Bool {
        #if os(macOS)
            cloudKitAvailable(iCloudServices: entitlement("com.apple.developer.icloud-services"))
        #else
            true
        #endif
    }

    /// Whether the value of the `com.apple.developer.icloud-services` entitlement includes CloudKit.
    public nonisolated static func cloudKitAvailable(iCloudServices value: Any?) -> Bool {
        (value as? [String])?.contains("CloudKit") ?? false
    }

    #if os(macOS)
        /// The value of one of this process's entitlements; `nil` when it has none.
        nonisolated static func entitlement(_ key: String) -> Any? {
            guard let task = SecTaskCreateFromSelf(nil) else { return nil }
            return SecTaskCopyValueForEntitlement(task, key as CFString, nil)
        }
    #endif
}
