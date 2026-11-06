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
}
