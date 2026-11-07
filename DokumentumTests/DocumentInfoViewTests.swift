#if os(iOS)
    import DokumentumCore
    import DokumentumTestSupport
    import Foundation
    import SwiftData
    import SwiftUI
    import Testing
    import UIKit

    @testable import Dokumentum

    /// The info panel's wiring, hosted in a window (review A of #57, D1): which document the title field saves
    /// to, that it saves before it shows the next document, and that it saves only through `TitleDraft`. The
    /// value rules themselves are in `TitleDraftTests`. In-memory store only.
    @MainActor
    struct DocumentInfoViewTests {
        private static let electricityBill = FixtureCatalog.documentID(1)
        private static let medicalInvoice = FixtureCatalog.documentID(2)

        /// The other device renamed the open document, and the library has not read it yet, so the untouched
        /// field shows the older title. Moving on to the next document must not save that older title back.
        @Test func aRemoteRenameSurvivesMovingOn() async throws {
            let container = try makeInMemoryContainer()
            FixtureSeeder.seedForUITests(container.mainContext)
            let model = LibraryModel(source: StoreLibrarySource(container: container))
            model.selectedDocumentID = Self.electricityBill

            let window = try hostedWindow(DocumentInfoView(model: model))
            defer {
                window.isHidden = true
                window.rootViewController = nil
            }
            try await waitForTitleField(in: window, toShow: "Electricity bill October")

            let other = ModelContext(container)
            let renamed = try #require(
                try other.fetch(FetchDescriptor<DokumentumCore.Document>()).first {
                    $0.instanceID == Self.electricityBill
                })
            renamed.title = "Renamed on the iPhone"
            try other.save()

            model.selectedDocumentID = Self.medicalInvoice
            // The view saves the old draft in the same `onChange` right before it shows the next document: once
            // the field shows it, the save of the old draft has run (or not).
            try await waitForTitleField(in: window, toShow: "Medical invoice")

            let stored = try #require(
                try ModelContext(container).fetch(FetchDescriptor<DokumentumCore.Document>()).first {
                    $0.instanceID == Self.electricityBill
                })
            #expect(stored.title == "Renamed on the iPhone")
        }

        // MARK: Hosting

        private func hostedWindow(_ view: some View) throws -> UIWindow {
            let scene = try #require(
                UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first,
                "the app host has a window scene")
            let window = UIWindow(windowScene: scene)
            window.rootViewController = UIHostingController(rootView: view)
            window.makeKeyAndVisible()
            return window
        }

        /// Waits until the hosted title field shows `text`. The field has no signal of its own, so this is the
        /// one poll (`TestSupport.waitUntil`), on the main actor that renders it.
        private func waitForTitleField(
            in window: UIWindow, toShow text: String, sourceLocation: SourceLocation = #_sourceLocation
        ) async throws {
            try await TestSupport.waitUntil("The title field does not show \(text)", sourceLocation: sourceLocation) {
                Self.textFields(in: window).contains { $0.text == text }
            }
        }

        private static func textFields(in view: UIView) -> [UITextField] {
            (view as? UITextField).map { [$0] } ?? view.subviews.flatMap { textFields(in: $0) }
        }
    }
#endif
