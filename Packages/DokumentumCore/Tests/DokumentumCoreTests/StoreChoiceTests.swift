import DokumentumCore
import DokumentumCoreTestSupport
import DokumentumTestSupport
import Foundation
import SwiftData
import Testing

/// Which store a launch opens. Test runs and UI-test launches never open the disk store or CloudKit.
@MainActor
struct StoreChoiceTests {
    @Test func testRunsAlwaysUseMemory() {
        for cloudKit in [false, true] {
            #expect(
                StoreChoice.decide(isRunningTests: true, arguments: [], cloudKitAvailable: cloudKit)
                    == .inMemory(seed: false))
            #expect(
                StoreChoice.decide(
                    isRunningTests: true, arguments: ["app", StoreChoice.uiTestSeedArgument, "YES"],
                    cloudKitAvailable: cloudKit) == .inMemory(seed: false))
        }
    }

    /// The tests run in a DEBUG build, where the launch arguments are honoured. UI tests pass them as pairs
    /// (`-UITestSeed YES`, #43), so the value must not matter.
    @Test func uiTestSeedUsesMemoryEvenWithCloudKit() {
        for arguments in [
            ["app", "-UITestSeed"], ["app", "-UITestSeed", "YES", "-ApplePersistenceIgnoreState", "YES"],
        ] {
            #expect(
                StoreChoice.decide(isRunningTests: false, arguments: arguments, cloudKitAvailable: true)
                    == .inMemory(seed: true))
        }
    }

    @Test func uiTestEmptyStoreUsesAnEmptyMemoryStore() {
        for arguments in [
            ["app", "-UITestEmptyStore"], ["app", "-UITestEmptyStore", "YES", "-ApplePersistenceIgnoreState", "YES"],
        ] {
            #expect(
                StoreChoice.decide(isRunningTests: false, arguments: arguments, cloudKitAvailable: true)
                    == .inMemory(seed: false))
            #expect(StoreChoice.isUITestLaunch(arguments: arguments))
        }
        #expect(!StoreChoice.isUITestLaunch(arguments: ["app", "-ApplePersistenceIgnoreState", "YES"]))
    }

    @Test func diskStoreFollowsTheCloudKitEntitlement() {
        #expect(StoreChoice.decide(isRunningTests: false, arguments: ["app"], cloudKitAvailable: false) == .local)
        #expect(StoreChoice.decide(isRunningTests: false, arguments: ["app"], cloudKitAvailable: true) == .cloudKit)
        #expect(
            StoreChoice.cloudKit.isOnDisk && StoreChoice.local.isOnDisk && !StoreChoice.inMemory(seed: true).isOnDisk)
    }

    @Test func hostedTestRunChoosesMemory() {
        #expect(ArchiveStore.currentChoice() == .inMemory(seed: false))
    }

    /// The entitlement's value is the list of iCloud services; only one with CloudKit opens a CloudKit store.
    @Test func cloudKitNeedsTheCloudKitService() {
        #expect(ArchiveStore.cloudKitAvailable(iCloudServices: ["CloudKit"]))
        #expect(ArchiveStore.cloudKitAvailable(iCloudServices: ["CloudDocuments", "CloudKit"]))
        #expect(!ArchiveStore.cloudKitAvailable(iCloudServices: ["CloudDocuments"]))
        #expect(!ArchiveStore.cloudKitAvailable(iCloudServices: "CloudKit"))
        #expect(!ArchiveStore.cloudKitAvailable(iCloudServices: nil))
        #if os(macOS)
            // The test runner is not signed with the app's entitlements, so a macOS test process opens no CloudKit
            // store (the development VM's unsigned path, Xcode Cloud's ad hoc tests).
            #expect(!ArchiveStore.cloudKitAvailable())
        #endif
    }

    @Test func anInMemoryStoreNeverTouchesTheDisk() throws {
        SQLLog.enable()
        let folder = try TestSupport.makeTemporaryDirectory()
        let url = folder.appending(path: "Never.store")
        let opened = ArchiveStore.makeContainer(
            for: .inMemory(seed: false), at: url, fallbackURL: folder.appending(path: "NeverEither.store"))
        let container = TestSupport.keepAlive(opened.container)
        #expect(opened.store == .inMemory)
        let configuration = try #require(container.configurations.first)
        #expect(configuration.isStoredInMemoryOnly)
        #expect(configuration.cloudKitContainerIdentifier == nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)
    }

    @Test func onlyASeededStoreIsSeeded() throws {
        SQLLog.enable()
        let seed: (ModelContext) -> Void = { context in
            context.insert(Document(title: "Sample"))
            try? context.save()
        }
        let seeded = ArchiveStore.makeContainer(for: .inMemory(seed: true), seed: seed)
        let empty = ArchiveStore.makeContainer(for: .inMemory(seed: false), seed: seed)
        TestSupport.keepAlive(seeded.container)
        TestSupport.keepAlive(empty.container)
        #expect(seeded.store == .sampleData)
        #expect(empty.store == .inMemory)
        #expect(try seeded.container.mainContext.fetchCount(FetchDescriptor<Document>()) == 1)
        #expect(try empty.container.mainContext.fetchCount(FetchDescriptor<Document>()) == 0)
    }

    @Test func aLocalStoreOpensAtItsFile() throws {
        SQLLog.enable()
        let folder = try TestSupport.makeTemporaryDirectory()
        let url = folder.appending(path: "Sub/Archive.store")
        let fallback = folder.appending(path: "Sub/Fallback.store")
        let opened = ArchiveStore.makeContainer(for: .local, at: url, fallbackURL: fallback)
        TestSupport.keepAlive(opened.container)
        #expect(opened.store == .local)
        #expect(opened.container.configurations.first?.url == url)
        #expect(opened.container.configurations.first?.cloudKitContainerIdentifier == nil)
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(!FileManager.default.fileExists(atPath: fallback.path))
    }

    /// When the store file cannot be opened at all, the second fallback file is used, not a crash.
    @Test func anUnopenableStoreFallsBackToTheSecondFile() throws {
        SQLLog.enable()
        let folder = try TestSupport.makeTemporaryDirectory()
        // A regular file where the store's folder should be: the folder cannot be created.
        let blocker = folder.appending(path: "Blocked")
        try Data("not a folder".utf8).write(to: blocker)
        let fallback = folder.appending(path: "Fallback/Archive-local.store")
        let opened = ArchiveStore.makeContainer(
            for: .local, at: blocker.appending(path: "Archive.store"), fallbackURL: fallback)
        TestSupport.keepAlive(opened.container)
        #expect(opened.store == .localFallback)
        #expect(opened.container.configurations.first?.url == fallback)
    }

    /// When the CloudKit open fails, the archive opens locally at the same file, so the user still sees it;
    /// the second fallback file is not even created. The opener fails the CloudKit step without CloudKit:
    /// the CloudKit configuration is built but never opened.
    @Test func aFailedCloudKitOpenFallsBackToLocalAtTheSameFile() throws {
        SQLLog.enable()
        let folder = try TestSupport.makeTemporaryDirectory()
        let url = folder.appending(path: "Archive.store")
        let fallback = folder.appending(path: "Archive-local.store")
        var tried: [(url: URL, cloudKit: String?)] = []
        let failCloudKit: (ModelConfiguration) throws -> ModelContainer = { configuration in
            tried.append((configuration.url, configuration.cloudKitContainerIdentifier))
            if configuration.cloudKitContainerIdentifier != nil { throw CocoaError(.featureUnsupported) }
            return try ArchiveStore.open(configuration)
        }
        let opened = ArchiveStore.makeContainer(
            for: .cloudKit, at: url, fallbackURL: fallback, opener: failCloudKit)
        TestSupport.keepAlive(opened.container)
        #expect(opened.store == .local)
        #expect(opened.container.configurations.first?.url == url)
        #expect(opened.container.configurations.first?.cloudKitContainerIdentifier == nil)
        #expect(tried.map(\.url) == [url, url])
        #expect(tried.map(\.cloudKit) == [ArchiveStore.cloudKitContainerIdentifier, nil])
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(!FileManager.default.fileExists(atPath: fallback.path))
    }

    /// Making a container changes no global state: only `openAtLaunch` records the store. Another test in this
    /// process may call `openAtLaunch(.inMemory(seed: false))` at the same time, so `opened` is either unset or
    /// that, never what this test made.
    @Test func makingAContainerLeavesTheOpenedStoreAlone() {
        SQLLog.enable()
        let opened = ArchiveStore.makeContainer(for: .inMemory(seed: true))
        TestSupport.keepAlive(opened.container)
        #expect(opened.store == .sampleData)
        #expect(ArchiveStore.opened != .sampleData)
        #expect(ArchiveStore.current !== opened.container)
    }

    /// The only test in this process that calls `openAtLaunch`; it writes the process-wide record.
    @Test func openAtLaunchRecordsTheStore() {
        SQLLog.enable()
        let container = TestSupport.keepAlive(ArchiveStore.openAtLaunch(.inMemory(seed: false)))
        #expect(ArchiveStore.opened == .inMemory)
        #expect(ArchiveStore.current === container)
        #expect(container.configurations.first?.isStoredInMemoryOnly == true)
    }

    /// A UI-test launch stays away from real data like a test run (DEBUG builds).
    @Test func aUITestLaunchIsIsolated() {
        #expect(TestEnvironment.isIsolated(isRunningTests: false, arguments: ["app", "-UITestSeed", "YES"]))
        #expect(TestEnvironment.isIsolated(isRunningTests: false, arguments: ["app", "-UITestEmptyStore", "YES"]))
        #expect(TestEnvironment.isIsolated(isRunningTests: true, arguments: ["app"]))
        #expect(
            !TestEnvironment.isIsolated(
                isRunningTests: false, arguments: ["app", "-ApplePersistenceIgnoreState", "YES"]))
    }
}
