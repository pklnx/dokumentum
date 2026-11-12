import DokumentumKit
import SwiftUI

/// A chip of the search field and its suggestion (#7, part 3, P3): "Tag: Steuer › 2024", "Correspondent: Finanzamt",
/// "Type: Bescheid", "Inbox". VoiceOver reads the title; the symbol is decoration.
struct SearchTokenLabel: View {
    let token: SearchToken
    /// The tag's display path, the correspondent's or type's name; unused for the Inbox.
    let name: String

    var body: some View {
        label
            .accessibilityIdentifier(AccessibilityID.searchToken(token))
    }

    @ViewBuilder
    private var label: some View {
        switch token {
        case .tag: Label("Tag: \(name)", systemImage: "tag")
        case .correspondent: Label("Correspondent: \(name)", systemImage: "person")
        case .documentType: Label("Type: \(name)", systemImage: "doc.text")
        case .inbox: Label("Inbox", systemImage: "tray")
        }
    }
}
