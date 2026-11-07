import DokumentumCore
import DokumentumTestSupport
import Foundation
import SwiftData
import Testing

@testable import Dokumentum

/// The hosted test bundle starts inside the real app, sees its internals and links the test helpers.
struct AppHostTests {
    @Test func theAppHostsTheTests() {
        #expect(Bundle.main.bundleIdentifier == "space.pklnx.Dokumentum")
        #expect(Bundle.main.bundleURL.lastPathComponent == "Dokumentum.app")
    }

    @Test func theTestsSeeTheAppsInternals() {
        #expect(DokumentumApp.rootIdentifier == "dokumentum.root")
    }

    @Test func theAppCarriesTheGermanCatalog() {
        #expect(Bundle.main.localizations.contains("de"))
    }

    /// The app starts with its hosted tests, so it has to know that it is in a test run.
    @Test func liveIsIsolatedInTheAppHost() {
        #expect(TestEnvironment.isRunningTests)
        #expect(TestEnvironment.isIsolated)
        #expect(ProcessingEnvironment.live.defaultsSuite == nil)
        #expect(ProcessingEnvironment.current.defaultsSuite == nil)
    }

    /// The app opens its store when it starts, so the hosted tests start inside an app that opened one: in a
    /// test run always in memory, never the archive on disk or CloudKit.
    @Test @MainActor func theHostOpenedAnInMemoryStoreAtLaunch() throws {
        #expect(ArchiveStore.opened == .inMemory)
        let container = try #require(ArchiveStore.current)
        #expect(container.configurations.first?.isStoredInMemoryOnly == true)
        #expect(container.configurations.first?.cloudKitContainerIdentifier == nil)
    }

    /// Making a container in a test leaves the launch record alone (only `openAtLaunch` writes it).
    @Test @MainActor func makingAContainerLeavesTheLaunchStoreAlone() {
        let launched = ArchiveStore.current
        let made = ArchiveStore.makeContainer(for: .inMemory(seed: true))
        withExtendedLifetime(made) {
            #expect(made.store == .sampleData)
            #expect(ArchiveStore.opened == .inMemory)
            #expect(ArchiveStore.current === launched)
            #expect(ArchiveStore.current !== made.container)
        }
    }
}
