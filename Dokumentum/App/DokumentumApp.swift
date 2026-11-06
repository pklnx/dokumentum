// Imported so every build proves that both packages resolve and link; step 1 starts using them.
import DokumentumCore
import DokumentumKit
import SwiftUI

@main
struct DokumentumApp: App {
    /// Finds the root view in UI tests, independent of the language.
    nonisolated static let rootIdentifier = "dokumentum.root"

    var body: some Scene {
        WindowGroup {
            Text("Dokumentum")
                .padding()
                .accessibilityIdentifier(Self.rootIdentifier)
        }
    }
}
