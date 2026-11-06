import DokumentumCore
import DokumentumTestSupport
import Foundation
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
}
