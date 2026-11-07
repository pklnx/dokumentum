import DokumentumKit
import Testing

/// The title of an imported file (PQ2).
struct ImportTitleTests {
    @Test(arguments: [
        ("Stromrechnung.pdf", "Stromrechnung"),
        ("Stromrechnung.PDF", "Stromrechnung"),
        ("Rechnung 2024.03.pdf", "Rechnung 2024.03"),
        ("archive.tar.gz", "archive.tar"),
        ("  Vertrag Miete.pdf  ", "Vertrag Miete"),
        ("Vertrag .pdf", "Vertrag"),
        ("Ohne Endung", "Ohne Endung"),
        ("Bericht v1.2 final", "Bericht v1.2 final"),
        ("Notiz.", "Notiz."),
        (".pdf", ""),
        ("", ""),
    ])
    func theExtensionGoes(fileName: String, title: String) {
        #expect(importTitle(fromFileName: fileName) == title)
    }
}
